"""生成 App 图标：Kimi 小脸（与 App 内 KimiFace 同一套几何），浅色 / 深色 / 着色三种外观。

用法：python3 scripts/make_app_icon.py
输出到 KimiCode/Assets.xcassets/AppIcon.appiconset/，并写好 Contents.json。
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # 超采样，边缘更平滑
OUT = os.path.join(os.path.dirname(__file__), "..", "KimiCode", "Assets.xcassets", "AppIcon.appiconset")

# App 内 KimiFace：24×16 的块、圆角 2.3、眼睛 3×4.5、间距 6、整体偏移 (2.7, -2.8)。
FACE_W, FACE_H, RADIUS = 24, 16, 2.3
EYE_W, EYE_H, EYE_GAP = 3, 4.5, 6
EYE_DX, EYE_DY = 2.7, -2.8
SCALE = 600 / FACE_W  # 小脸占画布宽度约 59%

KIMI_LIGHT = (0x17, 0x83, 0xFF)
KIMI_DARK = (0x1A, 0x88, 0xFF)


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        img.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img.resize((size, size))


def draw_face(canvas, face_color, eye_color, shadow=None):
    s = SCALE * SS
    cx, cy = canvas.width / 2, canvas.height / 2
    w, h = FACE_W * s, FACE_H * s
    box = [cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2]

    if shadow:
        layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).rounded_rectangle(
            [box[0], box[1] + 18 * SS, box[2], box[3] + 18 * SS], radius=RADIUS * s, fill=shadow
        )
        layer = layer.filter(ImageFilter.GaussianBlur(28 * SS))
        canvas.alpha_composite(layer)

    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle(box, radius=RADIUS * s, fill=face_color)
    ecx, ecy = cx + EYE_DX * s, cy + EYE_DY * s
    for sign in (-1, 1):
        ex = ecx + sign * (EYE_GAP / 2 + EYE_W / 2) * s
        d.rectangle(
            [ex - EYE_W / 2 * s, ecy - EYE_H / 2 * s, ex + EYE_W / 2 * s, ecy + EYE_H / 2 * s],
            fill=eye_color,
        )


def render(background, face_color, eye_color, shadow=None, transparent=False):
    big = SIZE * SS
    if transparent:
        canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    else:
        canvas = background.resize((big, big)).convert("RGBA")
    draw_face(canvas, face_color, eye_color, shadow)
    img = canvas.resize((SIZE, SIZE), Image.LANCZOS)
    return img if transparent else img.convert("RGB")


def main():
    os.makedirs(OUT, exist_ok=True)
    light_bg = vertical_gradient(SIZE, (0xFF, 0xFF, 0xFF), (0xEE, 0xF3, 0xFA))
    dark_bg = vertical_gradient(SIZE, (0x1C, 0x1F, 0x26), (0x08, 0x09, 0x0C))

    render(light_bg, KIMI_LIGHT + (255,), (255, 255, 255, 255), shadow=(23, 131, 255, 70)).save(
        os.path.join(OUT, "AppIcon-Light.png")
    )
    # 深色外观：系统会自己铺深色底，这里给实底也可以；保留实底，跟浅色一致可控。
    render(dark_bg, KIMI_DARK + (255,), (255, 255, 255, 255), shadow=(26, 136, 255, 90)).save(
        os.path.join(OUT, "AppIcon-Dark.png")
    )
    # 着色外观：灰度图，系统按用户选的颜色染色。
    render(dark_bg, (235, 235, 235, 255), (40, 40, 40, 255)).convert("L").save(
        os.path.join(OUT, "AppIcon-Tinted.png")
    )

    contents = {
        "images": [
            {"filename": "AppIcon-Light.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
                "filename": "AppIcon-Dark.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            },
            {
                "appearances": [{"appearance": "luminosity", "value": "tinted"}],
                "filename": "AppIcon-Tinted.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            },
        ],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
