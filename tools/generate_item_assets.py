from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math

SIZE = 256
SCALE = 3
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "items"
SERVER_OUT = Path(r"C:\Users\GameMaster\Desktop\FiveM Server\txData\QBCore_E66DFA.base\resources\[qb]\qb-inventory\html\images")
FONT = Path(r"C:\Windows\Fonts\arialbd.ttf")


def pt(x, y):
    return int(x * SCALE), int(y * SCALE)


def box(x1, y1, x2, y2):
    return (*pt(x1, y1), *pt(x2, y2))


def width(n):
    return max(1, int(n * SCALE))


def font(n):
    return ImageFont.truetype(str(FONT), width(n))


def canvas():
    return Image.new("RGBA", (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))


def shadow_line(img, points, fill, w, shadow=8):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    shifted = [(x * SCALE + shadow * SCALE, y * SCALE + shadow * SCALE) for x, y in points]
    d.line(shifted, fill=(0, 0, 0, 100), width=width(w), joint="curve")
    layer = layer.filter(ImageFilter.GaussianBlur(width(5)))
    img.alpha_composite(layer)
    ImageDraw.Draw(img).line([pt(x, y) for x, y in points], fill=fill, width=width(w), joint="curve")


def shadow_shape(img, kind, coords, fill, outline=(20, 28, 35, 230), w=3):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(layer)
    shifted = tuple(v + 8 * SCALE for v in coords)
    getattr(sd, kind)(shifted, fill=(0, 0, 0, 105))
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(width(6))))
    d = ImageDraw.Draw(img)
    getattr(d, kind)(coords, fill=fill, outline=outline, width=width(w))


def finish(img, name):
    image = img.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    image.save(OUT / f"{name}.png", optimize=True)
    image.save(SERVER_OUT / f"{name}.png", optimize=True)

def draw_rod(name, color, accent, grip):
    img = canvas()
    d = ImageDraw.Draw(img)
    shadow_line(img, [(42, 203), (73, 170), (111, 127), (151, 83), (205, 39)], color, 8)
    d.line([pt(43, 202), pt(72, 171)], fill=grip, width=width(13))
    d.line([pt(45, 199), pt(70, 174)], fill=(255, 255, 255, 80), width=width(2))
    for t in (0.28, 0.5, 0.72):
        x = 42 + (205 - 42) * t
        y = 203 + (39 - 203) * t
        d.ellipse(box(x - 7, y - 7, x + 7, y + 7), fill=(25, 34, 40, 255), outline=accent, width=width(3))
    d.ellipse(box(58, 166, 101, 209), fill=(31, 38, 43, 255), outline=accent, width=width(5))
    d.ellipse(box(68, 176, 91, 199), fill=accent, outline=(235, 245, 250, 220), width=width(2))
    d.line([pt(89, 194), pt(108, 207)], fill=(36, 43, 47, 255), width=width(5))
    d.ellipse(box(103, 202, 113, 212), fill=accent)
    finish(img, name)


def draw_reel(name, metal, spool, electric=False):
    img = canvas()
    d = ImageDraw.Draw(img)
    shadow_shape(img, "ellipse", box(43, 49, 200, 206), metal, w=5)
    d.ellipse(box(69, 75, 174, 180), fill=(25, 32, 38, 255), outline=(225, 235, 239, 190), width=width(4))
    d.ellipse(box(86, 92, 157, 163), fill=spool, outline=(12, 20, 25, 255), width=width(4))
    d.ellipse(box(105, 111, 138, 144), fill=metal, outline=(245, 250, 250, 180), width=width(3))
    d.line([pt(174, 108), pt(217, 82)], fill=(30, 38, 43, 255), width=width(10))
    d.ellipse(box(205, 67, 229, 91), fill=spool, outline=(20, 28, 32, 255), width=width(3))
    d.rectangle(box(111, 196, 133, 231), fill=(39, 45, 48, 255), outline=(12, 18, 22, 255), width=width(3))
    if electric:
        d.rounded_rectangle(box(40, 116, 77, 167), radius=width(7), fill=(15, 28, 38, 255), outline=(64, 220, 255, 255), width=width(3))
        d.line([pt(49, 143), pt(58, 132), pt(57, 142), pt(69, 133)], fill=(255, 231, 81, 255), width=width(3))
    finish(img, name)


def draw_line(name, pounds, color):
    img = canvas()
    d = ImageDraw.Draw(img)
    shadow_shape(img, "ellipse", box(38, 48, 218, 208), (54, 64, 72, 255), w=5)
    d.ellipse(box(57, 67, 199, 190), fill=color, outline=(220, 235, 240, 220), width=width(4))
    for y in range(80, 184, 11):
        d.arc(box(62, y - 7, 194, y + 13), 5, 175, fill=(255, 255, 255, 100), width=width(2))
    d.ellipse(box(91, 91, 165, 165), fill=(34, 42, 48, 255), outline=(220, 230, 235, 220), width=width(4))
    text = f"{pounds}LB"
    f = font(24)
    bb = d.textbbox((0, 0), text, font=f)
    d.text(pt(128 - (bb[2] / SCALE) / 2, 116), text, font=f, fill=(245, 248, 250, 255), stroke_width=width(1), stroke_fill=(10, 15, 20, 255))
    finish(img, name)


def draw_hook(name, number, color):
    img = canvas()
    d = ImageDraw.Draw(img)
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.arc(box(62, 48, 205, 210), 55, 290, fill=(0, 0, 0, 110), width=width(16))
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(width(6))))
    d.arc(box(56, 42, 199, 204), 55, 290, fill=color, width=width(12))
    d.line([pt(165, 59), pt(169, 31)], fill=color, width=width(12))
    d.polygon([pt(55, 153), pt(35, 128), pt(72, 141)], fill=(225, 235, 240, 255), outline=(18, 25, 30, 255))
    d.ellipse(box(153, 22, 184, 48), fill=(30, 38, 43, 255), outline=color, width=width(6))
    d.rounded_rectangle(box(151, 165, 218, 214), radius=width(12), fill=(23, 31, 38, 235), outline=color, width=width(3))
    d.text(pt(176, 168), str(number), font=font(32), anchor="ma", fill=(250, 250, 250, 255))
    finish(img, name)

def draw_float(name, body, stripe, smart=False):
    img = canvas()
    d = ImageDraw.Draw(img)
    shadow_line(img, [(128, 29), (128, 81)], (205, 218, 225, 255), 5)
    shadow_shape(img, "ellipse", box(84, 66, 172, 205), body, w=4)
    d.rectangle(box(87, 107, 169, 137), fill=stripe)
    d.arc(box(84, 66, 172, 205), 0, 360, fill=(25, 32, 37, 255), width=width(4))
    d.line([pt(128, 202), pt(128, 229)], fill=(210, 220, 226, 255), width=width(5))
    d.ellipse(box(119, 220, 137, 238), fill=(34, 42, 48, 255), outline=(220, 230, 235, 255), width=width(2))
    if smart:
        d.rounded_rectangle(box(102, 145, 154, 174), radius=width(6), fill=(12, 29, 39, 255), outline=(61, 226, 255, 255), width=width(2))
        for x, h in ((112, 6), (122, 12), (132, 18), (142, 10)):
            d.line([pt(x, 164), pt(x, 164 - h)], fill=(82, 241, 164, 255), width=width(3))
    finish(img, name)


def draw_worm(name):
    img = canvas()
    shadow_line(img, [(38, 168), (67, 121), (108, 145), (144, 94), (207, 122)], (201, 92, 82, 255), 25)
    d = ImageDraw.Draw(img)
    d.line([pt(38, 168), pt(67, 121), pt(108, 145), pt(144, 94), pt(207, 122)], fill=(232, 132, 117, 255), width=width(18), joint="curve")
    for x, y in ((62, 128), (95, 139), (129, 114), (158, 98), (187, 113)):
        d.line([pt(x - 3, y - 6), pt(x + 5, y + 4)], fill=(156, 62, 62, 160), width=width(2))
    finish(img, name)


def draw_minnow(name):
    draw_fish(name, (124, 178, 194), (205, 227, 230), "minnow")


def draw_shrimp(name):
    img = canvas()
    d = ImageDraw.Draw(img)
    shadow_shape(img, "ellipse", box(45, 60, 192, 203), (235, 122, 94, 255), w=4)
    d.ellipse(box(74, 78, 196, 177), fill=(0, 0, 0, 0), outline=(255, 177, 144, 255), width=width(23))
    d.polygon([pt(52, 150), pt(25, 123), pt(61, 125)], fill=(246, 150, 120, 255), outline=(80, 45, 42, 255))
    for a in range(0, 5):
        x = 90 + a * 20
        d.line([pt(x, 162), pt(x - 9, 191)], fill=(236, 146, 116, 255), width=width(4))
    d.ellipse(box(175, 99, 185, 109), fill=(18, 22, 24, 255))
    d.line([pt(181, 101), pt(229, 74)], fill=(246, 166, 133, 255), width=width(2))
    finish(img, name)


def draw_insect(name):
    img = canvas()
    d = ImageDraw.Draw(img)
    shadow_shape(img, "ellipse", box(87, 55, 169, 211), (76, 55, 34, 255), w=4)
    d.ellipse(box(96, 41, 160, 101), fill=(45, 34, 25, 255), outline=(212, 165, 69, 255), width=width(4))
    d.ellipse(box(65, 87, 125, 166), fill=(209, 167, 72, 210), outline=(82, 54, 25, 255), width=width(3))
    d.ellipse(box(131, 87, 191, 166), fill=(209, 167, 72, 210), outline=(82, 54, 25, 255), width=width(3))
    for y in (102, 133, 165):
        d.line([pt(96, y), pt(49, y - 25)], fill=(47, 34, 24, 255), width=width(5))
        d.line([pt(160, y), pt(207, y - 25)], fill=(47, 34, 24, 255), width=width(5))
    finish(img, name)


def draw_liver(name):
    img = canvas()
    shadow_shape(img, "polygon", [*pt(40, 145), *pt(71, 77), *pt(150, 57), *pt(215, 111), *pt(190, 185), *pt(103, 206)], (132, 44, 51, 255), w=4)
    d = ImageDraw.Draw(img)
    d.line([pt(79, 90), pt(159, 76), pt(193, 113)], fill=(232, 116, 107, 160), width=width(7))
    finish(img, name)

def draw_lure(name, kind, color):
    img = canvas()
    d = ImageDraw.Draw(img)
    if kind == "spinner":
        shadow_shape(img, "ellipse", box(54, 47, 151, 138), (218, 225, 230, 255), w=4)
        d.line([pt(130, 120), pt(174, 174)], fill=(94, 101, 106, 255), width=width(5))
        d.ellipse(box(146, 144, 193, 191), fill=color, outline=(28, 34, 38, 255), width=width(3))
    else:
        shadow_shape(img, "ellipse", box(45, 78, 203, 166), color, w=4)
        d.ellipse(box(67, 95, 80, 108), fill=(245, 250, 250, 255), outline=(20, 25, 29, 255), width=width(2))
        if kind == "jig":
            for x in range(122, 194, 9):
                d.line([pt(x, 151), pt(x + 15, 205)], fill=(235, 229, 110, 255), width=width(3))
        elif kind == "crankbait":
            d.polygon([pt(108, 159), pt(145, 205), pt(162, 157)], fill=(224, 231, 235, 230), outline=(28, 35, 40, 255))
        else:
            d.polygon([pt(183, 103), pt(225, 82), pt(199, 127)], fill=(231, 237, 240, 235), outline=(28, 35, 40, 255))
    for ox in (0, 45):
        x = 111 + ox
        d.arc(box(x, 157, x + 38, 215), 25, 290, fill=(205, 215, 220, 255), width=width(4))
    finish(img, name)


def draw_fish(name, body, accent, species="generic"):
    img = canvas()
    d = ImageDraw.Draw(img)
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.ellipse(box(45, 75, 205, 183), fill=(0, 0, 0, 105))
    ld.polygon([pt(53, 113), pt(15, 65), pt(24, 164)], fill=(0, 0, 0, 105))
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(width(7))))
    d.polygon([pt(58, 126), pt(17, 75), pt(27, 176)], fill=accent, outline=(20, 29, 34, 255))
    d.ellipse(box(47, 70, 218, 180), fill=body, outline=(20, 29, 34, 255), width=width(4))
    d.polygon([pt(115, 77), pt(148, 37), pt(166, 82)], fill=accent, outline=(20, 29, 34, 255))
    d.polygon([pt(115, 174), pt(151, 212), pt(166, 169)], fill=accent, outline=(20, 29, 34, 255))
    d.ellipse(box(184, 93, 202, 111), fill=(246, 249, 242, 255), outline=(18, 23, 26, 255), width=width(2))
    d.ellipse(box(190, 98, 198, 106), fill=(8, 12, 14, 255))
    d.arc(box(185, 116, 223, 149), 70, 190, fill=(35, 42, 45, 255), width=width(3))
    if species in ("bass", "pike"):
        d.line([pt(70, 112), pt(174, 133)], fill=accent, width=width(8))
    elif species in ("trout", "salmon"):
        for x, y in ((82, 104), (108, 91), (130, 122), (155, 101), (95, 143), (169, 143)):
            d.ellipse(box(x - 4, y - 4, x + 4, y + 4), fill=accent)
    elif species == "mackerel":
        for x in range(77, 172, 18):
            d.line([pt(x, 78), pt(x + 13, 108)], fill=accent, width=width(5))
    elif species == "tuna":
        d.line([pt(61, 138), pt(177, 150)], fill=accent, width=width(9))
    elif species == "swordfish":
        d.polygon([pt(207, 112), pt(250, 121), pt(208, 133)], fill=accent, outline=(20, 29, 34, 255))
    elif species == "shark":
        d.polygon([pt(129, 73), pt(155, 25), pt(171, 79)], fill=accent, outline=(20, 29, 34, 255))
        d.arc(box(183, 117, 226, 154), 65, 190, fill=(245, 245, 240, 255), width=width(5))
    elif species == "catfish":
        d.line([pt(201, 124), pt(245, 94)], fill=accent, width=width(3))
        d.line([pt(201, 132), pt(245, 160)], fill=accent, width=width(3))
    elif species == "golden":
        for x, y in ((77, 86), (121, 59), (167, 73), (183, 164), (115, 194)):
            d.line([pt(x, y - 10), pt(x, y + 10)], fill=(255, 248, 176, 255), width=width(3))
            d.line([pt(x - 10, y), pt(x + 10, y)], fill=(255, 248, 176, 255), width=width(3))
    finish(img, name)

def draw_boot(name):
    img = canvas()
    d = ImageDraw.Draw(img)
    shadow_shape(img, "polygon", [*pt(80, 34), *pt(155, 34), *pt(148, 146), *pt(217, 174), *pt(205, 218), *pt(68, 211), *pt(53, 173), *pt(88, 145)], (81, 72, 57, 255), w=5)
    d.line([pt(86, 159), pt(145, 165)], fill=(132, 113, 78, 255), width=width(5))
    d.line([pt(72, 196), pt(203, 200)], fill=(39, 46, 43, 255), width=width(8))
    for x, y in ((105, 71), (132, 91), (102, 125), (174, 186)):
        d.ellipse(box(x - 6, y - 4, x + 6, y + 4), fill=(41, 75, 57, 180))
    finish(img, name)


def draw_bottle(name):
    img = canvas()
    d = ImageDraw.Draw(img)
    shadow_shape(img, "polygon", [*pt(99, 29), *pt(157, 29), *pt(157, 72), *pt(184, 102), *pt(177, 223), *pt(79, 223), *pt(72, 102), *pt(99, 72)], (90, 188, 183, 125), w=4)
    d.rectangle(box(101, 27, 155, 47), fill=(132, 84, 48, 255), outline=(57, 41, 29, 255), width=width(3))
    d.polygon([pt(91, 126), pt(164, 115), pt(170, 178), pt(98, 188)], fill=(236, 219, 172, 255), outline=(86, 69, 43, 255))
    d.line([pt(107, 142), pt(152, 136)], fill=(124, 93, 54, 255), width=width(2))
    d.line([pt(110, 155), pt(145, 150)], fill=(124, 93, 54, 255), width=width(2))
    finish(img, name)


def draw_map(name):
    img = canvas()
    d = ImageDraw.Draw(img)
    shadow_shape(img, "polygon", [*pt(45, 50), *pt(104, 68), *pt(155, 48), *pt(216, 68), *pt(205, 211), *pt(151, 190), *pt(98, 209), *pt(40, 190)], (222, 190, 121, 255), w=4)
    d.line([pt(101, 69), pt(97, 207)], fill=(143, 109, 59, 180), width=width(3))
    d.line([pt(156, 50), pt(151, 190)], fill=(143, 109, 59, 180), width=width(3))
    d.line([pt(66, 166), pt(91, 137), pt(122, 153), pt(164, 105)], fill=(97, 118, 91, 255), width=width(6))
    d.line([pt(169, 88), pt(194, 113)], fill=(151, 45, 40, 255), width=width(7))
    d.line([pt(194, 88), pt(169, 113)], fill=(151, 45, 40, 255), width=width(7))
    finish(img, name)


def draw_chest(name):
    img = canvas()
    d = ImageDraw.Draw(img)
    shadow_shape(img, "rectangle", box(37, 104, 219, 215), (106, 62, 36, 255), w=5)
    d.pieslice(box(37, 43, 219, 166), 180, 360, fill=(125, 76, 40, 255), outline=(36, 29, 22, 255), width=width(5))
    for x in (61, 181):
        d.rectangle(box(x, 73, x + 16, 214), fill=(193, 145, 51, 255), outline=(65, 48, 25, 255), width=width(2))
    d.rectangle(box(108, 129, 148, 175), fill=(224, 176, 62, 255), outline=(59, 43, 24, 255), width=width(3))
    d.ellipse(box(121, 141, 135, 155), fill=(41, 34, 26, 255))
    finish(img, name)


def draw_gem(name, kind, color):
    img = canvas()
    d = ImageDraw.Draw(img)
    if kind == "pearl":
        shadow_shape(img, "ellipse", box(48, 48, 208, 208), color, w=4)
        d.ellipse(box(73, 65, 136, 121), fill=(255, 255, 255, 175))
    elif kind == "coin":
        shadow_shape(img, "ellipse", box(44, 44, 212, 212), color, w=6)
        d.ellipse(box(64, 64, 192, 192), fill=(0, 0, 0, 0), outline=(255, 225, 118, 255), width=width(6))
        d.text(pt(128, 105), "Z", font=font(54), anchor="ma", fill=(102, 67, 22, 255))
    else:
        pts = [pt(128, 31), pt(211, 91), pt(178, 205), pt(78, 205), pt(45, 91)]
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon([(x + width(8), y + width(8)) for x, y in pts], fill=(0, 0, 0, 110))
        img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(width(6))))
        d.polygon(pts, fill=color, outline=(18, 48, 60, 255), width=width(4))
        d.polygon([pt(128, 31), pt(158, 91), pt(128, 179), pt(98, 91)], fill=(222, 254, 255, 170))
        d.line([pt(45, 91), pt(211, 91)], fill=(245, 255, 255, 200), width=width(3))
    finish(img, name)

def generate_all():
    OUT.mkdir(parents=True, exist_ok=True)
    SERVER_OUT.mkdir(parents=True, exist_ok=True)

    draw_rod("fishing_rod_common", (172, 119, 65, 255), (208, 166, 78, 255), (79, 53, 34, 255))
    draw_rod("fishing_rod_rare", (45, 68, 75, 255), (69, 204, 218, 255), (30, 40, 43, 255))
    draw_rod("fishing_rod_epic", (47, 48, 56, 255), (171, 91, 241, 255), (27, 28, 32, 255))
    draw_rod("fishing_rod_legendary", (230, 173, 48, 255), (255, 227, 111, 255), (83, 41, 29, 255))

    draw_reel("reel_cheap", (98, 105, 106, 255), (171, 103, 54, 255))
    draw_reel("reel_carbon", (39, 47, 53, 255), (54, 202, 213, 255))
    draw_reel("reel_electric", (54, 64, 74, 255), (84, 231, 255, 255), True)

    for name, pounds, color in (("line_10", 10, (185, 228, 233, 255)), ("line_20", 20, (104, 211, 162, 255)), ("line_40", 40, (237, 183, 65, 255)), ("line_60", 60, (224, 80, 76, 255))):
        draw_line(name, pounds, color)
    for n, color in ((2, (225, 232, 235, 255)), (4, (121, 205, 219, 255)), (6, (237, 181, 71, 255)), (8, (207, 116, 232, 255))):
        draw_hook(f"hook_{n}", n, color)

    draw_float("float_wood", (151, 91, 49, 255), (234, 220, 176, 255))
    draw_float("float_foam", (232, 237, 232, 255), (239, 75, 71, 255))
    draw_float("float_smart", (34, 48, 57, 255), (51, 218, 236, 255), True)

    draw_worm("worm")
    draw_minnow("minnow")
    draw_shrimp("shrimp")
    draw_insect("insect")
    draw_liver("chicken_liver")
    draw_lure("spinner", "spinner", (239, 85, 67, 255))
    draw_lure("jig", "jig", (83, 181, 209, 255))
    draw_lure("crankbait", "crankbait", (237, 161, 44, 255))
    draw_lure("topwater", "topwater", (97, 211, 130, 255))

    fish = {
        "fish_bass": ((78, 137, 92), (32, 73, 54), "bass"),
        "fish_trout": ((160, 183, 158), (222, 87, 89), "trout"),
        "fish_catfish": ((91, 110, 117), (51, 67, 72), "catfish"),
        "fish_salmon": ((226, 123, 105), (102, 63, 70), "salmon"),
        "fish_pike": ((116, 143, 69), (57, 74, 38), "pike"),
        "fish_mackerel": ((80, 142, 164), (36, 72, 91), "mackerel"),
        "fish_tuna": ((54, 105, 153), (202, 193, 84), "tuna"),
        "fish_swordfish": ((62, 119, 163), (178, 213, 225), "swordfish"),
        "fish_shark": ((110, 132, 143), (55, 74, 84), "shark"),
        "fish_golden": ((235, 178, 45), (255, 224, 103), "golden"),
    }
    for name, (body, accent, species) in fish.items():
        draw_fish(name, (*body, 255), (*accent, 255), species)

    draw_boot("old_boot")
    draw_bottle("bottle_message")
    draw_map("treasure_map")
    draw_chest("treasure_chest")
    draw_gem("pearl", "pearl", (230, 224, 226, 255))
    draw_gem("ancient_coin", "coin", (205, 148, 48, 255))
    draw_gem("diamond", "diamond", (100, 225, 245, 255))


def make_preview():
    names = sorted(p.stem for p in OUT.glob("*.png"))
    cell_w, cell_h, cols = 180, 205, 8
    rows = math.ceil(len(names) / cols)
    sheet = Image.new("RGBA", (cell_w * cols, cell_h * rows), (12, 19, 27, 255))
    d = ImageDraw.Draw(sheet)
    f = ImageFont.truetype(str(FONT), 16)
    for i, name in enumerate(names):
        x, y = (i % cols) * cell_w, (i // cols) * cell_h
        icon = Image.open(OUT / f"{name}.png").resize((156, 156), Image.Resampling.LANCZOS)
        sheet.alpha_composite(icon, (x + 12, y + 5))
        d.text((x + cell_w / 2, y + 170), name, font=f, anchor="ma", fill=(230, 238, 244, 255))
    sheet.convert("RGB").save(ROOT / "assets" / "zfishing-items-preview.jpg", quality=92)


if __name__ == "__main__":
    generate_all()
    make_preview()
    print(f"Generated {len(list(OUT.glob('*.png')))} item images")
