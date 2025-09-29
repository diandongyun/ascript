from ascript.ios.ui import WebWindow
from ascript.ios.system import R, KeyValue, device
from ascript.ios import action
import requests
import json
import logging
import threading
import time
import sys
import random
import time
import random
import logging
from ascript.ios import system, action, screen
from ascript.ios.screen import FindImages, Ocr
from ascript.ios.system import R
import time
import random
import logging
from ascript.ios import system, action, screen
from ascript.ios.screen import FindImages, Ocr
from ascript.ios.system import R
from ascript.ios.system import R, KeyValue, device
import requests
import re
import unicodedata
import requests
from typing import Set
import socket
import requests
import time as pytime
import requests
import json
import time
import io
import base64
import os
import zipfile
import tempfile

API_URL = "http://216.167.11.87:5000/verify"
ui = None
running_scripts = {}
stop_event = threading.Event()
script_timers = {}


def verify_registration(code, email=None):
    try:
        device_id = device.get_device_id()
        data = {
            "type": "001",
            "code": code,
            "device_id": device_id
        }
        if email:
            data["email"] = email
        response = requests.post(
            API_URL,
            json=data,
            headers={"Content-Type": "application/json"},
            timeout=10
        )
        if response.status_code == 200:
            result = response.json()
            return result.get("success", False), result.get("message", "验证失败")
        else:
            return False, "服务器返回错误状态码"
    except requests.exceptions.RequestException as e:
        return False, "无法连接到验证服务器"
    except Exception as e:
        return False, "验证过程中发生错误"


PLATFORM_MAPPING = {
    "tiktok": "TikTok",
    "facebook": "Facebook",
    "instagram": "Instagram",
    "x": "X(Twitter)"
}


class ScreenResolutionManager:
    @staticmethod
    def get_screen_resolution():
        try:
            size = device.get_screen_size()
            return size[0], size[1]
        except Exception as e:
            return None, None

    @staticmethod
    def get_device_model():
        try:
            device_id = device.get_device_id()
            return f"iOS_Device_{device_id[:8]}"
        except Exception as e:
            return "Unknown_iOS_Device"

    @staticmethod
    def format_resolution_folder_name(width, height):
        return f"{width}x{height}"


class ImageDownloader:
    def __init__(self):
        self.img_folder = R.res("img")
        self.ensure_img_folder()
        self.resolution_manager = ScreenResolutionManager()

    def ensure_img_folder(self):
        if not os.path.exists(self.img_folder):
            os.makedirs(self.img_folder)

    def _get_resolution_folder(self):
        try:
            width, height = self.resolution_manager.get_screen_resolution()
            if not width or not height:
                return None
            folder_name = self.resolution_manager.format_resolution_folder_name(width, height)
            candidate = os.path.join(self.img_folder, folder_name)
            return candidate if os.path.isdir(candidate) else None
        except Exception:
            return None

    def request_images_by_resolution(self):
        try:
            # 改为本地读取：仅检查对应分辨率文件夹是否存在即可
            resolution_folder = self._get_resolution_folder()
            if resolution_folder and os.listdir(resolution_folder):
                return True
            # 若无对应分辨率文件夹，则回退为根img下的通用资源
            has_any = any(
                name.lower().endswith((".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff", ".webp"))
                for name in os.listdir(self.img_folder)
            ) if os.path.isdir(self.img_folder) else False
            return has_any
        except Exception:
            return False

    def list_downloaded_images(self):
        try:
            resolution_folder = self._get_resolution_folder()
            target_folder = resolution_folder if resolution_folder else self.img_folder
            img_files = os.listdir(target_folder)
            image_files = [f for f in img_files if f.lower().endswith((
                '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp'
            ))]
            return image_files
        except Exception:
            return []

    def show_device_not_supported(self, message):
        try:
            from ascript.ios.ui import WebWindow
            from ascript.ios.system import R
            def device_not_supported_handler(key, value):
                if key == "__onload__":
                    pass
                elif key == "close":
                    if hasattr(device_not_supported_handler, 'ui'):
                        device_not_supported_handler.ui.close()
            device_ui = WebWindow(R.ui("supported.html"), device_not_supported_handler)
            device_not_supported_handler.ui = device_ui
            device_ui.show()
        except Exception as e:
            pass


class YOLODetectionHelper:
    @staticmethod
    def send_image_for_detection(image):
        try:
            img_base64 = image_to_base64_png(image)
            if not img_base64:
                return None
            data = {
                "type": "004",
                "image": img_base64
            }
            response = requests.post(
                API_URL,
                json=data,
                headers={'Content-Type': 'application/json'},
                timeout=30
            )
            if response.status_code == 200:
                result = response.json()
                if result.get('success'):
                    return result.get('data', {})
                else:
                    return None
            else:
                return None
        except Exception as e:
            return None


STANDARD_UI_CLASSES = {
    'sousuo': 0,
    'guanbi': 1,
    'fasong': 2,
    'dianzan': 3,
    'pinglun': 4,
    'fenxiang': 5,
    'shouye': 6,
    'pinglundianzan': 7,
    'pingluntupian': 8,
    'pinglunbiaoqing': 9,
    'pinglun@': 10,
    'yinyue': 11,
    'didian': 12
}

MODEL_TO_STANDARD_MAPPING = {
    'dianzan': 'dianzan',
    'didian': 'didian',
    'fasong': 'fasong',
    'fenxiang': 'fenxiang',
    'guanbi': 'guanbi',
    'pinglun': 'pinglun',
    'pinglun@': 'pinglun@',
    'pinglunbiaoqing': 'pinglunbiaoqing',
    'pinglundianzan': 'pinglundianzan',
    'pingluntupian': 'pingluntupian',
    'shouye': 'shouye',
    'sousuo': 'sousuo',
    'yinyue': 'yinyue'
}

tiktok_tempText = None


def image_to_base64_png(image):
    try:
        buffer = io.BytesIO()
        image.save(buffer, format='PNG', optimize=False)
        buffer.seek(0)
        img_base64 = base64.b64encode(buffer.getvalue()).decode('utf-8')
        buffer.close()
        return img_base64
    except Exception as e:
        return None


def convert_to_standard_format(results, detection_method, needs_click=False):
    converted_results = []
    for result in results:
        center_x = result.get("center_x", 0)
        center_y = result.get("center_y", 0)
        rect_coords = result.get("rect", [0, 0, 0, 0])
        if len(rect_coords) >= 4:
            width = rect_coords[2] - rect_coords[0]
            height = rect_coords[3] - rect_coords[1]
        else:
            width = height = 0
        converted_result = {
            'center_x': center_x,
            'center_y': center_y,
            'x': rect_coords[0] if len(rect_coords) >= 4 else 0,
            'y': rect_coords[1] if len(rect_coords) >= 4 else 0,
            'width': width,
            'height': height,
            'confidence': result.get("confidence", 0.75),
            'rect': rect_coords,
            'detection_method': detection_method,
            'needs_click': needs_click
        }
        converted_results.append(converted_result)
    return converted_results


def detect_special_ui_states(ui_type, search_rect, confidence_threshold):
    if ui_type == 'shouye':
        try:
            selected_results = FindImages(
                [get_image_path("shouyeyixuanzhong.png")],
                confidence=confidence_threshold,
                rect=search_rect,
                mode=FindImages.M_MIX
            ).find_all()
            if selected_results:
                return convert_to_standard_format(selected_results, 'local_special')
        except Exception as e:
            pass
        try:
            unselected_results = FindImages(
                [get_image_path("shouyeweixuanzhong.png")],
                confidence=confidence_threshold,
                rect=search_rect,
                mode=FindImages.M_MIX
            ).find_all()
            if unselected_results:
                return convert_to_standard_format(unselected_results, 'local_special', needs_click=True)
        except Exception as e:
            pass
    return []


def _preferred_image_path(image_filename):
    try:
        base_folder = R.res("img")
        size = device.get_screen_size()
        width, height = size[0], size[1]
        resolution_folder = f"{width}x{height}"
        candidate = os.path.join(base_folder, resolution_folder, image_filename)
        if os.path.isfile(candidate):
            return candidate
        fallback = os.path.join(base_folder, image_filename)
        return fallback
    except Exception:
        return os.path.join(R.res("img"), image_filename)

def get_image_path(image_filename):
    # 对外统一方法，供FindImages使用
    return _preferred_image_path(image_filename)

def enhanced_local_detection(class_name, search_rect, confidence_threshold, max_retries=3):
    image_filename = f"{class_name}.png"
    for retry in range(max_retries):
        try:
            results = FindImages(
                [get_image_path(image_filename)],
                confidence=confidence_threshold,
                rect=search_rect,
                mode=FindImages.M_MIX
            ).find_all()
            if results:
                return convert_to_standard_format(results, 'local')
        except Exception as e:
            pass
        if retry < max_retries - 1:
            time.sleep(0.05)
    return []


def enhanced_detect_ui_elements(class_name, confidence_threshold=0.75, search_rect=None, enable_special_states=False):
    try:
        if class_name not in STANDARD_UI_CLASSES:
            return []
        size = device.get_screen_size()
        screen_width, screen_height = size[0], size[1]
        if search_rect:
            x1, y1, x2, y2 = search_rect
        else:
            x1, y1, x2, y2 = 0, 0, screen_width, screen_height
        if x1 >= x2 or y1 >= y2 or x1 < 0 or y1 < 0 or x2 > screen_width or y2 > screen_height:
            x1, y1, x2, y2 = 0, 0, screen_width, screen_height
        if enable_special_states:
            special_result = detect_special_ui_states(class_name, (x1, y1, x2, y2), confidence_threshold)
            if special_result:
                return special_result
        local_results = enhanced_local_detection(class_name, (x1, y1, x2, y2), confidence_threshold)
        if local_results:
            return local_results
        cloud_results = try_cloud_yolo_detection(class_name, (x1, y1, x2, y2), confidence_threshold)
        if cloud_results:
            return cloud_results
        return []
    except Exception as e:
        return []


def try_cloud_yolo_detection(class_name, search_rect, confidence_threshold):
    try:
        x1, y1, x2, y2 = search_rect
        size = device.get_screen_size()
        screen_width, screen_height = size[0], size[1]
        cropped_image = screen.capture((x1, y1, x2, y2))
        if not cropped_image:
            return []
        crop_offset_x = x1
        crop_offset_y = y1
        detection_result = YOLODetectionHelper.send_image_for_detection(cropped_image)
        if not detection_result or not detection_result.get('success'):
            return []
        all_detections = []
        detections_data = detection_result.get('detections', {})
        for level in ['high_confidence', 'medium_confidence', 'low_confidence']:
            all_detections.extend(detections_data.get(level, []))
        filtered_detections = []
        for detection in all_detections:
            if (detection['class_name'] == class_name and
                    detection['confidence'] >= confidence_threshold):
                bbox = detection['bbox']
                original_x = int(bbox['x'] + crop_offset_x)
                original_y = int(bbox['y'] + crop_offset_y)
                original_center_x = int(bbox['x'] + bbox['width'] / 2 + crop_offset_x)
                original_center_y = int(bbox['y'] + bbox['height'] / 2 + crop_offset_y)
                original_x2 = int(bbox['x'] + bbox['width'] + crop_offset_x)
                original_y2 = int(bbox['y'] + bbox['height'] + crop_offset_y)
                original_x = max(0, min(screen_width, original_x))
                original_y = max(0, min(screen_height, original_y))
                original_x2 = max(0, min(screen_width, original_x2))
                original_y2 = max(0, min(screen_height, original_y2))
                original_center_x = max(0, min(screen_width, original_center_x))
                original_center_y = max(0, min(screen_height, original_center_y))
                adjusted_detection = {
                    'center_x': original_center_x,
                    'center_y': original_center_y,
                    'x': original_x,
                    'y': original_y,
                    'width': bbox['width'],
                    'height': bbox['height'],
                    'confidence': detection['confidence'],
                    'rect': [original_x, original_y, original_x2, original_y2],
                    'detection_method': 'cloud'
                }
                filtered_detections.append(adjusted_detection)
        if not filtered_detections and confidence_threshold > 0.5:
            for detection in all_detections:
                if (detection['class_name'] == class_name and
                        detection['confidence'] >= 0.5):
                    bbox = detection['bbox']
                    original_x = int(bbox['x'] + crop_offset_x)
                    original_y = int(bbox['y'] + crop_offset_y)
                    original_center_x = int(bbox['x'] + bbox['width'] / 2 + crop_offset_x)
                    original_center_y = int(bbox['y'] + bbox['height'] / 2 + crop_offset_y)
                    original_x2 = int(bbox['x'] + bbox['width'] + crop_offset_x)
                    original_y2 = int(bbox['y'] + bbox['height'] + crop_offset_y)
                    original_x = max(0, min(screen_width, original_x))
                    original_y = max(0, min(screen_height, original_y))
                    original_x2 = max(0, min(screen_width, original_x2))
                    original_y2 = max(0, min(screen_height, original_y2))
                    original_center_x = max(0, min(screen_width, original_center_x))
                    original_center_y = max(0, min(screen_height, original_center_y))
                    adjusted_detection = {
                        'center_x': original_center_x,
                        'center_y': original_center_y,
                        'x': original_x,
                        'y': original_y,
                        'width': bbox['width'],
                        'height': bbox['height'],
                        'confidence': detection['confidence'],
                        'rect': [original_x, original_y, original_x2, original_y2],
                        'detection_method': 'cloud'
                    }
                    filtered_detections.append(adjusted_detection)
        return filtered_detections
    except Exception as e:
        return []


def check_comment_count_zero(comment_data):
    try:
        size = device.get_screen_size()
        screen_width, screen_height = size[0], size[1]
        comment_rect = comment_data['rect']
        comment_left_top_x = comment_rect[0]
        comment_left_top_y = comment_rect[1]
        comment_right_bottom_y = comment_rect[3]
        ocr_rect = (
            comment_left_top_x,
            comment_left_top_y,
            screen_width,
            int(screen_height * 0.95)
        )
        ocr_rect = (
            max(0, ocr_rect[0]),
            max(0, ocr_rect[1]),
            min(screen_width, ocr_rect[2]),
            min(screen_height, ocr_rect[3])
        )
        ocr_results = Ocr(
            rect=ocr_rect,
            confidence=0.1,
            pattern='0'
        ).paddleocr_v3()
        if not ocr_results:
            return True
        for result in ocr_results:
            if result['text'] == '0':
                zero_rect = result.get('rect', [])
                if len(zero_rect) >= 4:
                    if isinstance(zero_rect[0], (list, tuple)):
                        y_coords = [pos[1] for pos in zero_rect]
                        zero_left_top_y = min(y_coords)
                    else:
                        zero_left_top_y = zero_rect[1]
                    y_diff = zero_left_top_y - comment_right_bottom_y
                    if y_diff <= 70:
                        return False
        return True
    except Exception as e:
        return True


def check_slide_effect(search_rect, slide_action):
    try:
        before_slide_results = enhanced_local_detection('pinglundianzan', search_rect, 0.75)
        before_slide_data = [(r['center_x'], r['center_y']) for r in
                             before_slide_results] if before_slide_results else []
        slide_action()
        time.sleep(0.8)
        after_slide_results = enhanced_local_detection('pinglundianzan', search_rect, 0.75)
        after_slide_data = [(r['center_x'], r['center_y']) for r in after_slide_results] if after_slide_results else []
        if len(before_slide_data) != len(after_slide_data):
            return True
        size = device.get_screen_size()
        position_threshold = size[1] * 0.05
        for before_pos, after_pos in zip(sorted(before_slide_data), sorted(after_slide_data)):
            if (abs(before_pos[0] - after_pos[0]) > position_threshold or
                    abs(before_pos[1] - after_pos[1]) > position_threshold):
                return True
        return False
    except Exception as e:
        return False


def calculate_expand_click_position(rect):
    try:
        if not rect or len(rect) < 4:
            return None
        if isinstance(rect[0], (list, tuple)):
            x_coords = [pos[0] for pos in rect]
            y_coords = [pos[1] for pos in rect]
            x1, y1 = min(x_coords), min(y_coords)
            x2, y2 = max(x_coords), max(y_coords)
        else:
            x1, y1, x2, y2 = rect[0], rect[1], rect[2], rect[3]
        text_width = x2 - x1
        text_height = y2 - y1
        click_x = int(x1 + text_width * 0.9)
        click_y = int(y1 + text_height * 0.5)
        return (click_x, click_y)
    except Exception as e:
        return None


def tiktok_script(config=None):
    def download_resolution_images():
        try:
            downloader = ImageDownloader()
            success = downloader.request_images_by_resolution()
            if success:
                downloader.list_downloaded_images()
                return True
            else:
                return False
        except Exception as e:
            return False
    download_success = download_resolution_images()
    if not download_success:
        return
    def step1():
        system.app_stop(bundle_id="com.zhiliaoapp.musically")
        schemes = ["snssdk1233://"]
        for s in schemes:
            try:
                system.scheme_start(s)
                time.sleep(0.5)
            except Exception as e:
                pass
        step2()
    tiktok_temptime = None
    def step2():
        nonlocal tiktok_temptime
        def perform_registration_check_before_step3():
            nonlocal tiktok_temptime
            registration_code = KeyValue.get("registration_code", "")
            if not registration_code or not registration_code[0].isdigit():
                step3()
                return
            def get_local_time():
                return int(time.time())
            if tiktok_temptime is None:
                size = device.get_screen_size()
                width, height = size[0], size[1]
                click_x = int(width * 0.9)
                click_y = int(height * 0.95)
                action.click(click_x, click_y)
                time.sleep(2)
                screenshot = screen.capture()
                if screenshot:
                    try:
                        img_base64 = image_to_base64_png(screenshot)
                        if img_base64:
                            current_time = get_local_time()
                            data = {
                                "type": "002",
                                "image": img_base64,
                                "timestamp": current_time,
                                "device_id": device.get_device_id(),
                                "registration_code": registration_code
                            }
                            response = requests.post(
                                API_URL,
                                json=data,
                                headers={"Content-Type": "application/json"},
                                timeout=10
                            )
                        click_x_after = int(width * 0.1)
                        click_y_after = int(height * 0.95)
                        action.click(click_x_after, click_y_after)
                        time.sleep(0.2)
                        tiktok_temptime = current_time
                        step3()
                        return
                    except Exception as e:
                        click_x_after = int(width * 0.1)
                        click_y_after = int(height * 0.95)
                        action.click(click_x_after, click_y_after)
                        time.sleep(0.2)
                        tiktok_temptime = get_local_time()
                        step3()
                        return
                else:
                    step3()
                    return
            else:
                current_time = get_local_time()
                time_diff = (current_time - tiktok_temptime) / 60
                if time_diff < 10:
                    step3()
                    return
                else:
                    try:
                        data = {
                            "type": "002",
                            "timestamp": current_time,
                            "device_id": device.get_device_id(),
                            "registration_code": registration_code
                        }
                        response = requests.post(
                            API_URL,
                            json=data,
                            headers={"Content-Type": "application/json"},
                            timeout=10
                        )
                        tiktok_temptime = current_time
                    except Exception as e:
                        tiktok_temptime = current_time
                    step3()
                    return
        max_retries = 5
        retry_count = 0
        while retry_count < max_retries:
            size = device.get_screen_size()
            screen_width, screen_height = size[0], size[1]
            shouye_search_rect = (
                0,
                int(screen_height * 0.90),
                screen_width,
                screen_height
            )
            shouye_result = enhanced_detect_ui_elements('shouye', confidence_threshold=0.75,
                                                        search_rect=shouye_search_rect,
                                                        enable_special_states=False)
            if shouye_result:
                perform_registration_check_before_step3()
                return
            time.sleep(0.05)
            retry_count += 1
        step1()
    step3_retry_count = 0
    def step3():
        nonlocal step3_retry_count
        try:
            if step3_retry_count >= 3:
                step4()
                return
            step3_retry_count += 1
            size = device.get_screen_size()
            screen_width, screen_height = size[0], size[1]
            ocr_rect = (
                int(screen_width * 0.5),
                int(screen_height * 0.05),
                int(screen_width * 0.95),
                int(screen_height * 0.20)
            )
            target_texts = [
                "推荐", "推薦", "为你推荐", "為你推薦", "发现", "發現",
                "For You", "Recommended", "Discover", "Suggested",
                "おすすめ", "推奨", "発見", "フォーユー",
                "推荐", "발견", "포유",
                "สำหรับ你", "แนะนำ", "ค้นพบ",
                "Dành cho bạn", "Gợi ý", "Khám phá",
                "Untuk Anda", "Rekomendasi", "Temukan",
                "Для вас", "Рекомендации", "Открытия",
                "Para ti", "Recomendado", "Descubrir",
                "Para você", "Recomendado", "Descobrir",
                "Pour toi", "Recommandé", "Découvrir",
                "Für dich", "Empfohlen", "Entdecken",
                "Per te", "Consigliato", "Scopri",
                "Senin için", "Önerilen", "Keşfet",
                "من أجلك", "مقترح", "اكتشف",
                "आपके लिए", "सुझाव", "खोजें",
                "FYP"
            ]
            ocr_results = Ocr(
                rect=ocr_rect,
                confidence=0.1
            ).paddleocr_v3()
            found_text = None
            text_data = None
            if ocr_results:
                for result in ocr_results:
                    for target in target_texts:
                        if target in result['text']:
                            found_text = target
                            text_data = result
                            break
                    if found_text:
                        break
            if not found_text:
                step4()
                return
            center_x = text_data['center_x']
            center_y = text_data['center_y']
            action.click(center_x, center_y)
            time.sleep(0.5)
            left = text_data['rect'][0]
            bottom = text_data['rect'][3]
            right = text_data['rect'][2]
            text_height = text_data['rect'][3] - text_data['rect'][1]
            search_rect = (
                left,
                bottom,
                right + text_height,
                bottom + text_height
            )
            selected_result = None
            for i in range(3):
                try:
                    selected_result = FindImages(
                        [get_image_path("xuanzhong.png")],
                        confidence=0.85,
                        rect=search_rect,
                        mode=FindImages.M_MIX
                    ).find_all()
                    if selected_result:
                        break
                    time.sleep(0.3)
                except Exception as e:
                    pass
            step3_retry_count = 0
            step4()
        except Exception as e:
            step4()
    def step4():
        try:
            size = device.get_screen_size()
            screen_width, screen_height = size[0], size[1]
            start_x_min = int(screen_width * 0.3)
            start_x_max = int(screen_width * 0.7)
            start_y_min = int(screen_height * 0.7)
            start_y_max = int(screen_height * 0.8)
            start_x = random.randint(start_x_min, start_x_max)
            start_y = random.randint(start_y_min, start_y_max)
            end_x = start_x
            end_y = start_y - int(screen_height * 0.65)
            end_y = max(int(screen_height * 0.1), end_y)
            action.slide(
                start_x, start_y,
                end_x, end_y,
                duration=500
            )
            step5()
        except Exception as e:
            step3()
    def step5():
        time.sleep(0.5)
        try:
            size = device.get_screen_size()
            screen_width, screen_height = size[0], size[1]
            fenxiang_search_rect = (
                int(screen_width * 0.8),
                int(screen_height * 0.65),
                screen_width,
                int(screen_height * 0.9)
            )
            share_result = enhanced_detect_ui_elements('fenxiang', confidence_threshold=0.75,
                                                       search_rect=fenxiang_search_rect)
            if share_result:
                step6()
            else:
                step2()
        except Exception as e:
            step2()
    def step6():
        global tiktok_tempText
        tiktok_tempText = None
        class EnhancedTextMatcher:
            def __init__(self):
                self.special_chars_pattern = re.compile(r'[^\w\s]', re.UNICODE)
                self.whitespace_pattern = re.compile(r'\s+')
            def normalize_text(self, text: str) -> str:
                if not text:
                    return ""
                normalized = unicodedata.normalize('NFKC', text)
                normalized = normalized.lower()
                normalized = self.special_chars_pattern.sub(' ', normalized)
                normalized = self.whitespace_pattern.sub(' ', normalized)
                return normalized.strip()
            def extract_words(self, text: str) -> set:
                normalized = self.normalize_text(text)
                if not normalized:
                    return set()
                return set(word for word in normalized.split() if word)
            def exact_contains(self, text: str, keyword: str) -> bool:
                if not text or not keyword:
                    return False
                normalized_text = self.normalize_text(text)
                normalized_keyword = self.normalize_text(keyword)
                if not normalized_text or not normalized_keyword:
                    return False
                text_words = normalized_text.split()
                keyword_words = normalized_keyword.split()
                if len(keyword_words) == 1:
                    return keyword_words[0] in text_words
                keyword_phrase = ' '.join(keyword_words)
                return keyword_phrase in normalized_text
            def fuzzy_contains(self, text: str, keyword: str, similarity_threshold: float = 0.8) -> bool:
                if not text or not keyword:
                    return False
                normalized_text = self.normalize_text(text)
                normalized_keyword = self.normalize_text(keyword)
                if not normalized_text or not normalized_keyword:
                    return False
                if normalized_keyword in normalized_text:
                    return True
                text_words = self.extract_words(normalized_text)
                keyword_words = self.extract_words(normalized_keyword)
                if keyword_words and all(
                        any(kw_word in text_word or text_word in kw_word for text_word in text_words)
                        for kw_word in keyword_words
                ):
                    return True
                return self._substring_match(normalized_text, normalized_keyword)
            def _substring_match(self, text: str, keyword: str) -> bool:
                if len(keyword) <= 2:
                    return keyword in text
                keyword_len = len(keyword)
                text_len = len(text)
                for i in range(text_len - keyword_len + 1):
                    substring = text[i:i + keyword_len]
                    if self._calculate_similarity(substring, keyword) >= 0.85:
                        return True
                return False
            def _calculate_similarity(self, str1: str, str2: str) -> float:
                if not str1 or not str2:
                    return 0.0
                if str1 == str2:
                    return 1.0
                matches = sum(1 for a, b in zip(str1, str2) if a == b)
                return matches / max(len(str1), len(str2))
        class BigModel:
            def __init__(self, api_key: str, model: str = "GLM-4-Flash-250414"):
                self.api_key = api_key
                self.model = model
                self.api_url = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
                self.headers = {
                    "Authorization": f"Bearer {self.api_key}",
                    "Content-Type": "application/json"
                }
                self.system_prompt = """
                你是一个多语言短视频评论助手，请根据视频内容自动判断最适合的语言生成一条评论。
                要求：
                自动检测输入文本的主要语言，使用与输入文本相同的语言生成评论。如果多种语言混合，使用占比最多的语言。如果包含音乐名称或者内容则不对音乐部分的内容进行评论。
                禁止：
                - 负面或违规内容
                - 解释性文字
                只需输出评论内容，不要包含任何解释或说明。
                """
            def ask(self, msg: str):
                messages = [
                    {"role": "system", "content": self.system_prompt},
                    {"role": "user", "content": f"视频/影片内容：{msg}\n请生成一条最适合语言的评论"}
                ]
                payload = {
                    "model": self.model,
                    "messages": messages,
                    "temperature": 0.8,
                    "max_tokens": 50,
                    "do_sample": True
                }
                try:
                    response = requests.post(self.api_url, headers=self.headers, json=payload, timeout=15)
                    if response.status_code == 200:
                        try:
                            result = response.json()
                        except Exception as e:
                            return f"API响应JSON解析失败: {e}"
                        if "choices" not in result or not result["choices"]:
                            return "API响应无choices内容"
                        if "message" not in result["choices"][0] or "content" not in result["choices"][0]["message"]:
                            return "API响应choices[0]缺少message或content"
                        generated_comment = result["choices"][0]["message"]["content"].strip()
                        return generated_comment
                    else:
                        return f"API请求失败：{response.status_code}，响应: {response.text}"
                except Exception as e:
                    return f"发生错误：{str(e)}"
        try:
            size = device.get_screen_size()
            screen_width, screen_height = size[0], size[1]
            text_matcher = EnhancedTextMatcher()
            expand_button_rect = [
                int(screen_width * 0.3),
                int(screen_height * 0.82),
                int(screen_width * 0.85),
                int(screen_height * 0.97)
            ]
            expand_keywords = [
                "展开", "more", "全文", "詳細"
            ]
            expand_ocr_results = Ocr(rect=expand_button_rect, confidence=0.6).paddleocr_v3()
            expand_button_found = False
            expand_button_position = None
            if expand_ocr_results:
                for i, result in enumerate(expand_ocr_results):
                    text = result.get('text', '')
                    center_x = result.get('center_x', None)
                    center_y = result.get('center_y', None)
                    rect = result.get('rect', [])
                    confidence = result.get('confidence', 0)
                    for keyword in expand_keywords:
                        if text_matcher.exact_contains(text, keyword):
                            expand_button_found = True
                            expand_button_position = calculate_expand_click_position(rect)
                            if expand_button_position is None:
                                if center_x is not None and center_y is not None:
                                    expand_button_position = (center_x, center_y)
                                else:
                                    backup_center_x = int((expand_button_rect[0] + expand_button_rect[2]) / 2)
                                    backup_center_y = int((expand_button_rect[1] + expand_button_rect[3]) / 2)
                                    expand_button_position = (backup_center_x, backup_center_y)
                            break
                    if expand_button_found:
                        break
            if expand_button_found and expand_button_position:
                try:
                    action.click(expand_button_position[0], expand_button_position[1])
                    time.sleep(0.6)
                    size = device.get_screen_size()
                    screen_width, screen_height = size[0], size[1]
                    fenxiang_search_rect = (
                        int(screen_width * 0.8),
                        int(screen_height * 0.65),
                        screen_width,
                        int(screen_height * 0.9)
                    )
                    share_result = enhanced_detect_ui_elements('fenxiang', confidence_threshold=0.75,
                                                               search_rect=fenxiang_search_rect)
                    if share_result:
                        time.sleep(0.6)
                    else:
                        slide_start_x = int(screen_width * 0.5)
                        slide_start_y = int(screen_height * 0.2)
                        slide_end_x = int(screen_width * 0.5)
                        slide_end_y = int(screen_height * 0.8)
                        action.slide(slide_start_x, slide_start_y, slide_end_x, slide_end_y, duration=800)
                        time.sleep(0.8)
                        step4()
                        return
                except Exception as e:
                    pass
            if expand_button_found:
                ocr_rect = [
                    0,
                    int(screen_height * 0.35),
                    int(screen_width * 0.75),
                    int(screen_height * 0.9)
                ]
            else:
                ocr_rect = [
                    0,
                    int(screen_height * 0.65),
                    int(screen_width * 0.75),
                    int(screen_height * 0.9)
                ]
            ocr_results = Ocr(rect=ocr_rect, confidence=0.5).paddleocr_v3()
            filter_keywords = [
                "首页", "主页", "我", "搜索", "发现", "推荐", "收件箱", "好友",
                "Home", "Me", "Search", "Discover", "For You", "Inbox", "Friends"
            ]
            def is_filtered_enhanced(text: str) -> bool:
                for keyword in filter_keywords:
                    if text_matcher.exact_contains(text, keyword):
                        return True
                return False
            filtered_texts = []
            if ocr_results:
                for result in ocr_results:
                    text = result.get('text', '')
                    if text and not is_filtered_enhanced(text):
                        filtered_texts.append(text)
            if not filtered_texts:
                step3()
                return
            combined_text = ''.join(filtered_texts)
            blacklist = []
            tiktok_blacklist = KeyValue.get("tiktok_blacklist")
            if tiktok_blacklist:
                blacklist = [word.strip() for word in tiktok_blacklist.split('-') if word.strip()]
                for blackword in blacklist:
                    if text_matcher.exact_contains(combined_text, blackword):
                        step4()
                        return
            matched_keywords = []
            keywords = []
            tiktok_keywords = KeyValue.get("tiktok_keywords")
            if tiktok_keywords:
                keywords = [word.strip() for word in tiktok_keywords.split('-') if word.strip()]
                for keyword in keywords:
                    if text_matcher.exact_contains(combined_text, keyword):
                        matched_keywords.append(keyword)
            if not matched_keywords:
                step4()
                return
            ai = BigModel(api_key="63df1f4b0b15427da3ca282d3206a149.3ynJnG0u7YOlp9jI")
            response = ai.ask(combined_text)
            if not response or response.startswith((
                    "API请求失败", "发生错误", "API响应无choices内容",
                    "API响应choices[0]缺少message或content", "API响应JSON解析失败"
            )):
                step4()
                return
            tiktok_tempText = response
            step7()
        except Exception as e:
            step3()
    def step7():
        try:
            size = device.get_screen_size()
            screen_width, screen_height = size[0], size[1]
            dianzan_search_rect = (
                int(screen_width * 0.75),
                int(screen_height * 0.3),
                screen_width,
                int(screen_height * 0.75)
            )
            like_result = enhanced_detect_ui_elements('dianzan', confidence_threshold=0.75,
                                                      search_rect=dianzan_search_rect)
            if not like_result:
                step4()
                return
            like_data = like_result[0]
            like_center_x = like_data['center_x']
            like_center_y = like_data['center_y']
            action.click(like_center_x, like_center_y)
            time.sleep(0.5)
            pinglun_search_rect = (
                int(screen_width * 0.7),
                int(screen_height * 0.4),
                screen_width,
                screen_height
            )
            comment_result = enhanced_detect_ui_elements('pinglun', confidence_threshold=0.75,
                                                         search_rect=pinglun_search_rect)
            if not comment_result:
                step4()
                return
            comment_data = comment_result[0]
            center_x = comment_data['center_x']
            center_y = comment_data['center_y']
            should_continue = check_comment_count_zero(comment_data)
            if not should_continue:
                step4()
                return
            action.click(center_x, center_y)
            time.sleep(0.5)
            step8()
        except Exception as e:
            step4()
    def step8():
        try:
            size = device.get_screen_size()
            screen_width, screen_height = size[0], size[1]
            max_retries = 3
            retry_interval = 0.5
            found_both = False
            y_diff = None
            for attempt in range(1, max_retries + 1):
                guanbi_search_rect = (
                    int(screen_width * 0.8),
                    0,
                    screen_width,
                    int(screen_height * 0.4)
                )
                close_result = enhanced_detect_ui_elements('guanbi', confidence_threshold=0.75,
                                                           search_rect=guanbi_search_rect)
                biaoqing_search_rect = (
                    0,
                    int(screen_height * 0.8),
                    screen_width,
                    screen_height
                )
                emoji_result = enhanced_detect_ui_elements('pinglunbiaoqing', confidence_threshold=0.75,
                                                           search_rect=biaoqing_search_rect)
                if close_result and emoji_result:
                    close_center_y = close_result[0]['center_y']
                    emoji_center_y = emoji_result[0]['center_y']
                    y_diff = emoji_center_y - close_center_y
                    found_both = True
                    step9(y_diff)
                    break
                time.sleep(retry_interval)
            if not found_both:
                tap_x = int(screen_width * 0.95)
                tap_y = int(screen_height * 0.25)
                action.click(tap_x, tap_y)
                time.sleep(0.5)
                action.click(tap_x, tap_y)
                time.sleep(0.5)
                dianzan_search_rect = (
                    int(screen_width * 0.75),
                    int(screen_height * 0.3),
                    screen_width,
                    int(screen_height * 0.75)
                )
                like_result = enhanced_detect_ui_elements('dianzan', confidence_threshold=0.75,
                                                          search_rect=dianzan_search_rect)
                if like_result:
                    tap_x = int(screen_width * 0.95)
                    tap_y = int(screen_height * 0.25)
                    action.click(tap_x, tap_y)
                    time.sleep(0.5)
                    action.click(tap_x, tap_y)
                    time.sleep(0.5)
                    step4()
                else:
                    tap_x = int(screen_width * 0.95)
                    tap_y = int(screen_height * 0.25)
                    action.click(tap_x, tap_y)
                    time.sleep(0.5)
                    action.click(tap_x, tap_y)
                    time.sleep(0.5)
                    step3()
        except Exception as e:
            size = device.get_screen_size()
            screen_width, screen_height = size[0], size[1]
            tap_x = int(screen_width * 0.95)
            tap_y = int(screen_height * 0.25)
            action.click(tap_x, tap_y)
            time.sleep(0.5)
            action.click(tap_x, tap_y)
            time.sleep(0.5)
            step3()
    def step9(y_diff):
        try:
            while True:
                size = device.get_screen_size()
                screen_width, screen_height = size[0], size[1]
                pinglundianzan_search_rect = (
                    int(screen_width * 0.6),
                    int(screen_height * 0.3),
                    screen_width,
                    screen_height
                )
                like_results = enhanced_detect_ui_elements('pinglundianzan', confidence_threshold=0.75,
                                                           search_rect=pinglundianzan_search_rect)
                if not like_results:
                    tap_x = int(screen_width * 0.95)
                    tap_y = int(screen_height * 0.25)
                    action.click(tap_x, tap_y)
                    time.sleep(0.5)
                    action.click(tap_x, tap_y)
                    time.sleep(0.5)
                    dianzan_search_rect = (
                        int(screen_width * 0.75),
                        int(screen_height * 0.3),
                        screen_width,
                        int(screen_height * 0.75)
                    )
                    xihuan_result = enhanced_detect_ui_elements('dianzan', confidence_threshold=0.75,
                                                                search_rect=dianzan_search_rect)
                    KeyValue.save("tiktokpinglundianzan", "")
                    KeyValue.save("tiktokyidianzan", "")
                    if xihuan_result:
                        step4()
                    else:
                        step3()
                    return
                tiktokpinglundianzan = [
                    {
                        'center_x': result['center_x'],
                        'center_y': result['center_y']
                    } for result in like_results
                ]
                like_rate_str = KeyValue.get("tiktok_likeRate")
                like_limit_str = KeyValue.get("tiktok_likeLimit")
                if not like_rate_str or not like_limit_str:
                    tap_x = int(screen_width * 0.95)
                    tap_y = int(screen_height * 0.25)
                    action.click(tap_x, tap_y)
                    time.sleep(0.5)
                    action.click(tap_x, tap_y)
                    time.sleep(0.5)
                    step4()
                    return
                try:
                    like_rate = float(like_rate_str)
                    like_limit = int(like_limit_str)
                except (ValueError, TypeError):
                    tap_x = int(screen_width * 0.95)
                    tap_y = int(screen_height * 0.25)
                    action.click(tap_x, tap_y)
                    time.sleep(0.5)
                    action.click(tap_x, tap_y)
                    time.sleep(0.5)
                    step4()
                    return
                tiktokyidianzan = KeyValue.get("tiktokyidianzan")
                try:
                    tiktokyidianzan = int(tiktokyidianzan) if tiktokyidianzan is not None and str(
                        tiktokyidianzan).isdigit() else 0
                except:
                    tiktokyidianzan = 0
                total_likes = len(like_results)
                click_count = round(total_likes * like_rate / 100)
                click_count = max(1, min(click_count, like_limit - tiktokyidianzan))
                if click_count <= 0:
                    KeyValue.save("tiktokpinglundianzan", "")
                    KeyValue.save("tiktokyidianzan", "")
                    step10()
                    return
                selected_points = random.sample(tiktokpinglundianzan, click_count)
                for point in selected_points:
                    action.click(point['center_x'], point['center_y'])
                    tiktokyidianzan += 1
                    time.sleep(0.05)
                KeyValue.save("tiktokyidianzan", str(tiktokyidianzan))
                if tiktokyidianzan >= like_limit:
                    KeyValue.save("tiktokpinglundianzan", "")
                    KeyValue.save("tiktokyidianzan", "")
                    step10()
                    return
                slide_success = False
                start_x_min = int(screen_width * 0.3)
                start_x_max = int(screen_width * 0.7)
                start_y_min = int(screen_height * 0.75)
                start_y_max = int(screen_height * 0.9)
                start_x = random.randint(start_x_min, start_x_max)
                start_y = random.randint(start_y_min, start_y_max)
                slide_distance = abs(y_diff) if y_diff is not None else int(screen_height * 0.4)
                end_y = start_y - slide_distance
                def slide_action():
                    action.slide(start_x, start_y, start_x, end_y, duration=1000)
                slide_success = check_slide_effect(pinglundianzan_search_rect, slide_action)
                if slide_success:
                    KeyValue.save("tiktokpinglundianzan", "")
                    continue
                else:
                    KeyValue.save("tiktokpinglundianzan", "")
                    KeyValue.save("tiktokyidianzan", "")
                    step10()
                    return
        except Exception as e:
            KeyValue.save("tiktokpinglundianzan", "")
            KeyValue.save("tiktokyidianzan", "")
            tap_x = int(screen_width * 0.95)
            tap_y = int(screen_height * 0.25)
            action.click(tap_x, tap_y)
            time.sleep(0.5)
            action.click(tap_x, tap_y)
            time.sleep(0.5)
            step3()
    def step10():
        try:
            size = device.get_screen_size()
            screen_width, screen_height = size[0], size[1]
            biaoqing_search_rect = (
                int(screen_width * 0.5),
                int(screen_height * 0.5),
                screen_width,
                screen_height
            )
            emoji_result = enhanced_detect_ui_elements('pinglunbiaoqing', confidence_threshold=0.75,
                                                       search_rect=biaoqing_search_rect)
            if emoji_result:
                emoji_data = emoji_result[0]
                emoji_x = emoji_data['center_x']
                emoji_y = emoji_data['center_y']
                tap_x = max(int(screen_width * 0.3), emoji_x - 450)
                tap_y = emoji_y
                action.click(tap_x, tap_y)
                time.sleep(0.3)
                global tiktok_tempText
                comment_text = tiktok_tempText if tiktok_tempText is not None else ""
                if comment_text:
                    action.input(comment_text)
                    time.sleep(0.8)
                    send_search_rect = (
                        int(screen_width * 0.7),
                        int(screen_height * 0.45),
                        screen_width,
                        screen_height
                    )
                    send_result = enhanced_detect_ui_elements('fasong', confidence_threshold=0.75,
                                                              search_rect=send_search_rect)
                    if send_result:
                        send_pos = (send_result[0]['center_x'], send_result[0]['center_y'])
                        action.click(send_pos[0], send_pos[1])
                        time.sleep(0.5)
                    else:
                        traditional_send_result = FindImages(
                            [get_image_path("pinglunfasong.png")],
                            confidence=0.5,
                            rect=send_search_rect,
                            mode=FindImages.M_MIX
                        ).find_all()
                        if traditional_send_result:
                            send_pos = (traditional_send_result[0].get("center_x", 0),
                                        traditional_send_result[0].get("center_y", 0))
                            action.click(send_pos[0], send_pos[1])
                            time.sleep(0.5)
                        else:
                            tap_x = int(screen_width * 0.95)
                            tap_y = int(screen_height * 0.25)
                            action.click(tap_x, tap_y)
                            time.sleep(0.5)
                            action.click(tap_x, tap_y)
                            time.sleep(0.5)
                tap_x = int(screen_width * 0.95)
                tap_y = int(screen_height * 0.25)
                action.click(tap_x, tap_y)
                time.sleep(0.5)
                action.click(tap_x, tap_y)
                time.sleep(0.5)
                dianzan_search_rect = (
                    int(screen_width * 0.75),
                    int(screen_height * 0.3),
                    screen_width,
                    int(screen_height * 0.75)
                )
                xihuan_result = enhanced_detect_ui_elements('dianzan', confidence_threshold=0.75,
                                                            search_rect=dianzan_search_rect)
                if xihuan_result:
                    step4()
                else:
                    step3()
                return
            time.sleep(0.5)
            tap_x = int(screen_width * 0.95)
            tap_y = int(screen_height * 0.25)
            action.click(tap_x, tap_y)
            time.sleep(0.5)
            action.click(tap_x, tap_y)
            time.sleep(0.5)
            dianzan_search_rect = (
                int(screen_width * 0.75),
                int(screen_height * 0.3),
                screen_width,
                int(screen_height * 0.75)
            )
            xihuan_result = enhanced_detect_ui_elements('dianzan', confidence_threshold=0.75,
                                                        search_rect=dianzan_search_rect)
            if xihuan_result:
                step4()
            else:
                step3()
        except Exception as e:
            step3()
    step1()


def facebook_script(config):
    like_rate = float(config.get('likeRate', 50)) / 100
    like_limit = int(config.get('likeLimit', 100))
    try:
        runtime = int(config.get('runtime', 60)) * 60
        start_time = time.time()
        like_count = 0
        while not stop_event.is_set() and (time.time() - start_time) < runtime and like_count < like_limit:
            action.slide(400, 600, 400, 300, 500)
            time.sleep(2)
            if random.random() < like_rate:
                action.click(150, 700)
                like_count += 1
            time.sleep(1)
    except Exception as e:
        pass


def instagram_script(config):
    like_rate = float(config.get('likeRate', 50)) / 100
    like_limit = int(config.get('likeLimit', 100))
    try:
        runtime = int(config.get('runtime', 60)) * 60
        start_time = time.time()
        like_count = 0
        while not stop_event.is_set() and (time.time() - start_time) < runtime and like_count < like_limit:
            action.slide(400, 700, 400, 300, 500)
            time.sleep(2)
            if random.random() < like_rate:
                action.click(400, 500)
                action.click(400, 500)
                like_count += 1
            time.sleep(1)
    except Exception as e:
        pass


def x_script(config):
    like_rate = float(config.get('likeRate', 50)) / 100
    like_limit = int(config.get('likeLimit', 100))
    try:
        runtime = int(config.get('runtime', 60)) * 60
        start_time = time.time()
        like_count = 0
        while not stop_event.is_set() and (time.time() - start_time) < runtime and like_count < like_limit:
            action.slide(400, 600, 400, 300, 500)
            time.sleep(2)
            if random.random() < like_rate:
                action.click(300, 650)
                like_count += 1
            time.sleep(1)
    except Exception as e:
        pass


def start_script_with_timer(platform, config):
    global script_timers, running_scripts
    try:
        runtime_minutes = int(config.get('runtime', KeyValue.get(f"{platform}_runtime", "60") or 60))
    except Exception:
        runtime_minutes = 60
    jump_to_platform = (config.get('jumpTo') or KeyValue.get(f"{platform}_jumpTo", "选择平台"))
    if jump_to_platform == '选择平台' or not jump_to_platform:
        jump_to_platform = None
    script_functions = {
        'tiktok': tiktok_script,
        'facebook': facebook_script,
        'instagram': instagram_script,
        'x': x_script
    }
    if platform not in script_functions:
        return False
    stop_current_script(platform)

    def script_wrapper():
        try:
            script_functions[platform](config)
        except Exception as e:
            pass
        finally:
            cleanup_script(platform)

    script_thread = threading.Thread(target=script_wrapper, daemon=True)
    script_thread.start()
    running_scripts[platform] = script_thread

    def timer_callback():
        stop_current_script(platform)
        if jump_to_platform and jump_to_platform in script_functions and not stop_event.is_set():
            if ui:
                try:
                    ui.call(f"handlePlatformSwitch('{platform}', '{jump_to_platform}')")
                except Exception:
                    pass
            def start_next():
                time.sleep(1)
                if not stop_event.is_set():
                    try:
                        stop_event.clear()
                    except Exception:
                        pass
                    next_config = get_platform_config(jump_to_platform) or {}
                    start_script_with_timer(jump_to_platform, next_config)
                    if ui:
                        try:
                            ui.call(f"handleScriptStart('{jump_to_platform}')")
                        except Exception:
                            pass

            next_thread = threading.Thread(target=start_next, daemon=True)
            next_thread.start()

    timer = threading.Timer(runtime_minutes * 60, timer_callback)
    timer.start()
    script_timers[platform] = timer
    return True


def stop_current_script(platform):
    global running_scripts, script_timers
    if platform in script_timers:
        script_timers[platform].cancel()
        del script_timers[platform]
    if platform in running_scripts:
        thread = running_scripts[platform]
        if thread and thread.is_alive():
            stop_event.set()
            thread.join(timeout=5)
        del running_scripts[platform]


def cleanup_script(platform):
    global running_scripts, script_timers
    script_timers.pop(platform, None)
    running_scripts.pop(platform, None)


def get_platform_config(platform):
    try:
        keywords = KeyValue.get(f"{platform}_keywords", "")
        blacklist = KeyValue.get(f"{platform}_blacklist", "")
        like_rate = KeyValue.get(f"{platform}_likeRate", "50")
        like_limit = KeyValue.get(f"{platform}_likeLimit", "100")
        runtime = KeyValue.get(f"{platform}_runtime", "60")
        jump_to = KeyValue.get(f"{platform}_jumpTo", "选择平台")
        config = {
            "keywords": keywords,
            "blacklist": blacklist,
            "likeRate": like_rate,
            "likeLimit": like_limit,
            "runtime": runtime,
            "jumpTo": jump_to
        }
        return config
    except Exception as e:
        return None


def force_exit_application():
    try:
        stop_all_scripts()
    except:
        pass
    finally:
        os._exit(0)


def stop_all_scripts():
    global running_scripts, script_timers, ui, volume_key_registered
    stop_event.set()
    for platform, timer in list(script_timers.items()):
        try:
            timer.cancel()
        except Exception as e:
            pass
    script_timers.clear()
    for platform, thread in list(running_scripts.items()):
        try:
            if thread and thread.is_alive():
                thread.join(timeout=3)
        except Exception as e:
            pass
    running_scripts.clear()
    if volume_key_registered:
        try:
            volume_key_registered = False
        except Exception as e:
            pass
    if ui:
        try:
            ui.call("handleScriptStop()")
        except Exception as e:
            pass
    if ui:
        try:
            ui.close()
        except Exception as e:
            pass

    def delayed_exit():
        time.sleep(1)
        os._exit(0)

    exit_timer = threading.Timer(0.5, delayed_exit)
    exit_timer.start()


def register_volume_key():
    global volume_key_registered
    try:
        volume_key_registered = True
        return True
    except Exception as e:
        return False


def tunner(key, value):
    global ui, running_scripts, volume_key_registered
    if key == "__onload__":
        pass
    elif key == "register":
        try:
            data = json.loads(value)
            code = data.get("code", "")
            email = data.get("email", "")
            if not code:
                ui.call("updateErrorMessage('注册码不能为空')")
                return
            success, message = verify_registration(code, email)
            if success:
                KeyValue.save("registration_code", code)
                if email:
                    KeyValue.save("registration_email", email)
                ui.call("registrationSuccess()")
            else:
                KeyValue.save("registration_code", "")
                KeyValue.save("registration_email", "")
                escaped_message = message.replace("'", "\\'")
                ui.call(f"updateErrorMessage('{escaped_message}')")
        except Exception as e:
            ui.call("updateErrorMessage('注册过程出错')")
    elif key == "register_volume_key":
        register_volume_key()
    elif key == "request_config":
        platform = value
        if platform == "all":
            for p in ["tiktok", "facebook", "instagram", "x"]:
                config = {
                    "keywords": KeyValue.get(f"{p}_keywords", ""),
                    "blacklist": KeyValue.get(f"{p}_blacklist", ""),
                    "likeRate": KeyValue.get(f"{p}_likeRate", ""),
                    "likeLimit": KeyValue.get(f"{p}_likeLimit", ""),
                    "runtime": KeyValue.get(f"{p}_runtime", ""),
                    "jumpTo": KeyValue.get(f"{p}_jumpTo", "选择平台")
                }
                config_json = json.dumps(config)
                ui.call(f"updateConfig('{p}', {config_json})")
        else:
            config = {
                "keywords": KeyValue.get(f"{platform}_keywords", ""),
                "blacklist": KeyValue.get(f"{platform}_blacklist", ""),
                "likeRate": KeyValue.get(f"{platform}_likeRate", ""),
                "likeLimit": KeyValue.get(f"{platform}_likeLimit", ""),
                "runtime": KeyValue.get(f"{platform}_runtime", ""),
                "jumpTo": KeyValue.get(f"{platform}_jumpTo", "选择平台")
            }
            config_json = json.dumps(config)
            ui.call(f"updateConfig('{platform}', {config_json})")
    elif key == "save_config":
        try:
            data = json.loads(value)
            platform = data["platform"]
            config = data["config"]
            KeyValue.save(f"{platform}_keywords", config.get("keywords", ""))
            KeyValue.save(f"{platform}_blacklist", config.get("blacklist", ""))
            KeyValue.save(f"{platform}_likeRate", config.get("likeRate", ""))
            KeyValue.save(f"{platform}_likeLimit", config.get("likeLimit", ""))
            KeyValue.save(f"{platform}_runtime", config.get("runtime", ""))
            KeyValue.save(f"{platform}_jumpTo", config.get("jumpTo", "选择平台"))
        except Exception as e:
            pass
    elif key == "start_script":
        try:
            data = json.loads(value)
            platform = data["platform"]
            # 使用前端传入的配置，优先于存储
            config = data.get("config") or get_platform_config(platform) or {}
            stop_event.clear()
            if start_script_with_timer(platform, config):
                if ui:
                    try:
                        ui.call(f"handleScriptStart('{platform}')")
                    except Exception:
                        pass
        except Exception as e:
            pass
    elif key == "stop_all":
        stop_all_scripts()
    elif key.startswith("jump_to_"):
        platform = value
        pass
    elif key == "open_main_window":
        try:
            if ui:
                ui.close()
            ui = WebWindow(R.ui("ai.html"), tunner)
            ui.show()
        except Exception as e:
            pass


def check_registration():
    code = KeyValue.get("registration_code", "")
    if not code:
        return False
    success, _ = verify_registration(code)
    if not success:
        KeyValue.save("registration_code", "")
        KeyValue.save("registration_email", "")
    return success


try:
    # 检查注册状态并显示相应UI
    if check_registration():
        ui = WebWindow(R.ui("ai.html"), tunner)
    else:
        ui = WebWindow(R.ui("zhuce.html"), tunner)
    ui.show()
except KeyboardInterrupt:
    stop_all_scripts()
except Exception as e:
    print(f"应用启动失败: {e}")
    stop_all_scripts()
finally:
    pass