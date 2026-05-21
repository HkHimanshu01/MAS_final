"""
Build a fully native editable PPTX of the RCA Multi-Agent System slide.
Every element is a real PowerPoint shape — no embedded image.

Coordinate system: HTML slide is 1280x640 px. We map it to a PPTX slide
that is 13.333" x 6.667" (2:1 aspect). So 1 px = 0.01042" = 9525 EMUs.
"""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.dml import MSO_LINE_DASH_STYLE
from pptx.oxml.ns import qn
from lxml import etree

# ---------- Canvas setup ----------
SLIDE_W_PX = 1280
SLIDE_H_PX = 640
PX_TO_EMU = 9525  # 1 px @ 96 DPI = 9525 EMU; matches 13.333"/1280

def px(v):
    return Emu(int(v * PX_TO_EMU))

prs = Presentation()
prs.slide_width = px(SLIDE_W_PX)
prs.slide_height = px(SLIDE_H_PX)

blank = prs.slide_layouts[6]
slide = prs.slides.add_slide(blank)

# ---------- Theme colors ----------
WHITE   = RGBColor(0xFF, 0xFF, 0xFF)
HEADER  = RGBColor(0x44, 0x54, 0x6A)   # primary text
PRIMARY = RGBColor(0x44, 0x72, 0xC4)   # accent blue
PRI_DK  = RGBColor(0x2E, 0x5B, 0xAC)
LT_BLUE = RGBColor(0x5B, 0x9B, 0xD5)
PALE_BL = RGBColor(0xBD, 0xD7, 0xEE)
PALER_BL= RGBColor(0xDC, 0xE7, 0xF7)
EVEN_LT = RGBColor(0xEA, 0xF1, 0xFB)
GREY_DK = RGBColor(0x6B, 0x72, 0x80)
GREY_MD = RGBColor(0x7B, 0x87, 0x94)
GREY_LT = RGBColor(0xB4, 0xBC, 0xCD)
GREY_BG = RGBColor(0xF3, 0xF4, 0xF8)
CLAUDE_DK = RGBColor(0x5B, 0x7C, 0xB8)
CLAUDE_BG = RGBColor(0xEE, 0xF3, 0xFB)
GREEN   = RGBColor(0x70, 0xAD, 0x47)
GOLD    = RGBColor(0xFF, 0xD9, 0x66)
GOLD_DK = RGBColor(0xFF, 0xC0, 0x00)
BORDER_LT = RGBColor(0xE5, 0xE7, 0xEB)

# ---------- Helpers ----------
def add_rect(left_px, top_px, w_px, h_px, fill, line=None, line_w=None, shape=MSO_SHAPE.ROUNDED_RECTANGLE, corner=8):
    shp = slide.shapes.add_shape(shape, px(left_px), px(top_px), px(w_px), px(h_px))
    # Apply corner radius for rounded rect
    if shape == MSO_SHAPE.ROUNDED_RECTANGLE:
        # corner radius = ratio of shortest side
        try:
            shp.adjustments[0] = corner / min(w_px, h_px)
        except Exception:
            pass
    if fill is None:
        shp.fill.background()
    else:
        shp.fill.solid()
        shp.fill.fore_color.rgb = fill
    if line is None:
        shp.line.fill.background()
    else:
        shp.line.color.rgb = line
        if line_w is not None:
            shp.line.width = Pt(line_w)
    # Default: no text padding shifts
    tf = shp.text_frame
    tf.margin_left = Emu(0)
    tf.margin_right = Emu(0)
    tf.margin_top = Emu(0)
    tf.margin_bottom = Emu(0)
    tf.word_wrap = True
    return shp

def _hex(color):
    """Accepts RGBColor or 3-tuple, returns 6-hex string."""
    if isinstance(color, RGBColor):
        return str(color)
    return '{:02X}{:02X}{:02X}'.format(*color)

def add_gradient_rect(left_px, top_px, w_px, h_px, color_a, color_b, line=None, line_w=None,
                     shape=MSO_SHAPE.ROUNDED_RECTANGLE, corner=8, angle=135):
    shp = slide.shapes.add_shape(shape, px(left_px), px(top_px), px(w_px), px(h_px))
    if shape == MSO_SHAPE.ROUNDED_RECTANGLE:
        try:
            shp.adjustments[0] = corner / min(w_px, h_px)
        except Exception:
            pass
    # Build gradient fill via XML
    sppr = shp.fill._xPr
    # remove existing fill children
    for tag in ('a:solidFill','a:gradFill','a:blipFill','a:pattFill','a:noFill'):
        el = sppr.find(qn(tag))
        if el is not None:
            sppr.remove(el)
    grad = etree.SubElement(sppr, qn('a:gradFill'), {'flip':'none','rotWithShape':'1'})
    gsl = etree.SubElement(grad, qn('a:gsLst'))
    g1 = etree.SubElement(gsl, qn('a:gs'), {'pos':'0'})
    etree.SubElement(g1, qn('a:srgbClr'), {'val': _hex(color_a)})
    g2 = etree.SubElement(gsl, qn('a:gs'), {'pos':'100000'})
    etree.SubElement(g2, qn('a:srgbClr'), {'val': _hex(color_b)})
    etree.SubElement(grad, qn('a:lin'), {'ang': str(angle * 60000),'scaled':'0'})
    if line is None:
        shp.line.fill.background()
    else:
        shp.line.color.rgb = line
        if line_w is not None:
            shp.line.width = Pt(line_w)
    tf = shp.text_frame
    tf.margin_left = Emu(0); tf.margin_right = Emu(0)
    tf.margin_top = Emu(0); tf.margin_bottom = Emu(0)
    return shp

def set_text(shp, runs, align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, pad=(6,6,6,6)):
    """runs: list of (text, dict) where dict has font_size, bold, color, etc."""
    tf = shp.text_frame
    tf.margin_left = px(pad[0])
    tf.margin_top = px(pad[1])
    tf.margin_right = px(pad[2])
    tf.margin_bottom = px(pad[3])
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    # Replace first paragraph with our runs
    p = tf.paragraphs[0]
    p.alignment = align
    # Clear any default runs
    for r in list(p.runs):
        r._r.getparent().remove(r._r)
    p.text = ""
    for txt, opts in runs:
        if opts.get('newline'):
            p = tf.add_paragraph()
            p.alignment = align
            continue
        r = p.add_run()
        r.text = txt
        if 'size' in opts: r.font.size = Pt(opts['size'])
        if 'bold' in opts: r.font.bold = opts['bold']
        if 'color' in opts: r.font.color.rgb = opts['color']
        if 'spacing' in opts:
            # Letter spacing in points; pptx uses spc in hundredths of a point
            rPr = r._r.get_or_add_rPr()
            rPr.set('spc', str(int(opts['spacing'] * 100)))
        if 'name' in opts: r.font.name = opts['name']

def add_text(left_px, top_px, w_px, h_px, runs, align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, pad=(0,0,0,0)):
    tb = slide.shapes.add_textbox(px(left_px), px(top_px), px(w_px), px(h_px))
    set_text(tb, runs, align=align, anchor=anchor, pad=pad)
    return tb

FONT = "Inter"

# ============================================================
#  BACKGROUND
# ============================================================
# Slide background is white by default. Add the left gradient accent bar.
accent = add_gradient_rect(0, 0, 6, 640,
                           (0x44,0x54,0x6A), (0x44,0x72,0xC4),
                           shape=MSO_SHAPE.RECTANGLE, angle=180)

# ============================================================
#  HEADER  (top ~80px area)
# ============================================================
PAD_L = 56
PAD_R = 56
HEADER_TOP = 32

# Heading
add_text(PAD_L, HEADER_TOP, 700, 36, [
    ("RCA Multi-Agent System", {'size': 24, 'bold': True, 'color': HEADER, 'name': FONT})
])

# Subtitle (one line)
sub_runs = [
    ("Diagnoses bugs, proposes the fix, verifies with tests. Projected savings: ",
     {'size': 11, 'color': GREY_MD, 'name': FONT}),
    ("~15% of a developer's annual salary",
     {'size': 11, 'bold': True, 'color': PRI_DK, 'name': FONT}),
    (".", {'size': 11, 'color': GREY_MD, 'name': FONT}),
]
add_text(PAD_L, HEADER_TOP + 32, 900, 22, sub_runs)

# ----- Validated badge (top right) -----
BADGE_W = 200
BADGE_H = 36
BADGE_X = SLIDE_W_PX - PAD_R - BADGE_W
BADGE_Y = HEADER_TOP + 12

badge_bg = add_gradient_rect(BADGE_X, BADGE_Y, BADGE_W, BADGE_H,
                             (0xEA,0xF1,0xFB), (0xD9,0xE6,0xF7),
                             line=PRIMARY, line_w=1, corner=6, angle=135)

# Green dot
dot = add_rect(BADGE_X + 9, BADGE_Y + 15, 6, 6, GREEN,
               shape=MSO_SHAPE.OVAL, corner=3)

# Badge text (two lines)
add_text(BADGE_X + 22, BADGE_Y + 5, BADGE_W - 26, BADGE_H - 10, [
    ("VALIDATED", {'size': 7, 'bold': True, 'color': PRIMARY, 'spacing': 1.5, 'name': FONT}),
    ("", {'newline': True}),
    ("Tested on complex, buggy", {'size': 8.5, 'bold': True, 'color': HEADER, 'name': FONT}),
    ("", {'newline': True}),
    ("open-source GitHub repos", {'size': 8.5, 'bold': True, 'color': HEADER, 'name': FONT}),
])

# ============================================================
#  THREE COLUMNS
# ============================================================
COLS_TOP = 88
COLS_H = 460
GAP = 14
TOTAL_COL_W = SLIDE_W_PX - PAD_L - PAD_R - 2 * GAP
# columns: 0.8fr / 0.8fr / 1.4fr  → fractions 0.8 / 0.8 / 1.4 of 3.0
W1 = int(TOTAL_COL_W * (0.8 / 3.0))
W2 = int(TOTAL_COL_W * (0.8 / 3.0))
W3 = TOTAL_COL_W - W1 - W2  # remainder
X1 = PAD_L
X2 = X1 + W1 + GAP
X3 = X2 + W2 + GAP

def column(x, w, title, headline, big_time_str, big_time_unit, theme):
    """Draw a column. theme is dict with bg_a, bg_b, border, title_color, time_color, step_bg, step_time_color."""
    border_w = 2 if theme.get('emphasis') else 1.5
    add_gradient_rect(x, COLS_TOP, w, COLS_H,
                      theme['bg_a'], theme['bg_b'],
                      line=theme['border'], line_w=border_w, corner=12, angle=180)
    # Title (eyebrow)
    add_text(x + 16, COLS_TOP + 16, w - 32, 14, [
        (title, {'size': 7.5, 'bold': True, 'color': theme['title_color'], 'spacing': 1.5, 'name': FONT})
    ])
    # Headline + big time row
    add_text(x + 16, COLS_TOP + 32, int((w-32) * 0.62), 22, [
        (headline, {'size': 11, 'bold': True, 'color': HEADER, 'name': FONT})
    ])
    # Big time number (right side of row)
    big_x = x + w - 16 - 80
    add_text(big_x, COLS_TOP + 26, 80, 32, [
        (big_time_str, {'size': 22, 'bold': True, 'color': theme['time_color'], 'name': FONT}),
        (" " + big_time_unit, {'size': 9, 'bold': True, 'color': GREY_MD, 'name': FONT}),
    ], align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.BOTTOM)

    # Divider line under header
    div = add_rect(x + 14, COLS_TOP + 60, w - 28, 1, BORDER_LT, shape=MSO_SHAPE.RECTANGLE, corner=0)

    return COLS_TOP + 68  # y position to start steps

# Theme defs
THEME_MANUAL = dict(
    bg_a=(0xF3,0xF4,0xF8), bg_b=(0xFF,0xFF,0xFF),
    border=GREY_LT, title_color=GREY_DK, time_color=GREY_DK,
    step_icon_bg=RGBColor(0xE5,0xE7,0xEB),
    step_time_bg=RGBColor(0xF3,0xF4,0xF8),
    step_time_color=GREY_DK,
)
THEME_CLAUDE = dict(
    bg_a=(0xEE,0xF3,0xFB), bg_b=(0xFF,0xFF,0xFF),
    border=RGBColor(0x8F,0xAA,0xDC), title_color=CLAUDE_DK, time_color=CLAUDE_DK,
    step_icon_bg=RGBColor(0xD9,0xE2,0xF2),
    step_time_bg=CLAUDE_BG,
    step_time_color=CLAUDE_DK,
)
THEME_AGENT = dict(
    bg_a=(0xDC,0xE7,0xF7), bg_b=(0xFF,0xFF,0xFF),
    border=PRIMARY, title_color=PRI_DK, time_color=PRI_DK,
    step_icon_bg=PALE_BL,
    step_time_bg=PALER_BL,
    step_time_color=PRI_DK,
    emphasis=True,
)

step_y_manual = column(X1, W1, "OPTION 1: MANUAL", "Developer alone", "75", "min", THEME_MANUAL)
step_y_claude = column(X2, W2, "OPTION 2: VIBE CODING", "Dev + Claude Code (free-form)", "40", "min", THEME_CLAUDE)
step_y_agent = column(X3, W3, "OPTION 3: AGENTIC WORKFLOW", "Purpose-built RCA multi-agent system", "5", "min dev", THEME_AGENT)

# ---- Why-it-wins pills (under Option 3 headline area, before steps) ----
def pills_row(x, y, w, labels):
    pill_h = 18
    pill_gap = 4
    cur_x = x
    for label in labels:
        # rough width estimate: 7 px per char + 16 padding
        pw = 7 * len(label) + 16
        if cur_x + pw > x + w:
            # wrap to next line
            y += pill_h + 4
            cur_x = x
        add_rect(cur_x, y, pw, pill_h, PALER_BL, line=PALE_BL, line_w=0.75, corner=4)
        add_text(cur_x, y, pw, pill_h, [
            (label, {'size': 7.5, 'bold': True, 'color': PRI_DK, 'name': FONT, 'spacing': 0.4})
        ], align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
        cur_x += pw + pill_gap
    return y + pill_h

pills_end_y = pills_row(X3 + 16, step_y_agent, W3 - 32, [
    "Auto-Triggered", "Engineered Context", "Specialised Agents", "Built-in Guardrails"
])
step_y_agent = pills_end_y + 8

# ============================================================
#  STEP ROWS
# ============================================================
def step_row(x_col, y, w_col, icon, name, desc, time_str, theme, dashed=False):
    """Draw one step row inside a column."""
    margin = 14
    sx = x_col + margin
    sw = w_col - 2 * margin
    sh = 38  # row height
    # row background
    bg = add_rect(sx, y, sw, sh, WHITE, line=BORDER_LT, line_w=0.75, corner=8)
    if dashed:
        bg.line.dash_style = MSO_LINE_DASH_STYLE.DASH
        bg.line.color.rgb = PRIMARY
        bg.fill.solid()
        bg.fill.fore_color.rgb = EVEN_LT
    # Icon box
    add_rect(sx + 6, y + 5, 28, 28, theme['step_icon_bg'], shape=MSO_SHAPE.ROUNDED_RECTANGLE, corner=6)
    add_text(sx + 6, y + 5, 28, 28, [
        (icon, {'size': 14, 'name': 'Segoe UI Emoji'})
    ], align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    # Step name + desc
    text_x = sx + 42
    text_w = sw - 42 - 70  # leave 70 for time pill
    add_text(text_x, y + 5, text_w, 14, [
        (name, {'size': 9.5, 'bold': True, 'color': HEADER, 'name': FONT})
    ])
    if desc:
        add_text(text_x, y + 19, text_w, 14, [
            (desc, {'size': 8.5, 'color': GREY_MD, 'name': FONT})
        ])
    # Time pill (right)
    pill_w = 50
    pill_h = 18
    add_rect(sx + sw - pill_w - 6, y + 10, pill_w, pill_h, theme['step_time_bg'],
             shape=MSO_SHAPE.ROUNDED_RECTANGLE, corner=5)
    add_text(sx + sw - pill_w - 6, y + 10, pill_w, pill_h, [
        (time_str, {'size': 9, 'bold': True, 'color': theme['step_time_color'], 'name': FONT})
    ], align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    return y + sh + 8

# --- Manual steps ---
y = step_y_manual
y = step_row(X1, y, W1, "📝", "Read bug report", "Pick up the QA ticket.", "5 min", THEME_MANUAL)
y = step_row(X1, y, W1, "🔍", "Investigate codebase", "Hunts the cause across files.", "45 min", THEME_MANUAL)
y = step_row(X1, y, W1, "🔧", "Write the fix", "Makes the code change.", "15 min", THEME_MANUAL)
y = step_row(X1, y, W1, "✅", "Test the fix", "Runs tests to confirm.", "10 min", THEME_MANUAL)

# --- Vibe Coding steps ---
y = step_y_claude
y = step_row(X2, y, W2, "📝", "Read bug report", "Pick up the QA ticket.", "3 min", THEME_CLAUDE)
y = step_row(X2, y, W2, "💬", "Prompt & investigate", "Dev guides the AI turn by turn.", "25 min", THEME_CLAUDE)
y = step_row(X2, y, W2, "🔧", "Write the fix", "Dev refines the AI draft.", "7 min", THEME_CLAUDE)
y = step_row(X2, y, W2, "✅", "Test the fix", "Runs tests to confirm.", "5 min", THEME_CLAUDE)

# Vibe caveat box
caveat_y = y + 4
caveat_x = X2 + 14
caveat_w = W2 - 28
caveat_h = 32
add_rect(caveat_x, caveat_y, caveat_w, caveat_h, CLAUDE_BG, line=None, corner=4)
# Left accent bar on caveat
add_rect(caveat_x, caveat_y, 2, caveat_h, CLAUDE_DK, shape=MSO_SHAPE.RECTANGLE, corner=0)
add_text(caveat_x + 8, caveat_y + 4, caveat_w - 14, caveat_h - 6, [
    ("The catch: ", {'size': 8, 'bold': True, 'color': HEADER, 'name': FONT}),
    ("dev prompts ad-hoc, AI has no structure. On large repos it wanders and stalls.",
     {'size': 8, 'color': HEADER, 'name': FONT}),
])

# --- Agent steps ---
y = step_y_agent
# Step 1: hand bug to agent
y = step_row(X3, y, W3, "📝", "Hand bug to the agent", "Drop the QA report into the tool.", "1 min", THEME_AGENT)

# Step 2: agent investigates, fixes & tests — this is taller, contains the funnel
agent_step_x = X3 + 14
agent_step_w = W3 - 28
agent_step_y = y
agent_step_h = 140
add_rect(agent_step_x, agent_step_y, agent_step_w, agent_step_h, EVEN_LT,
         line=PRIMARY, line_w=1, corner=8)
# Icon
add_rect(agent_step_x + 6, agent_step_y + 5, 28, 28, PALE_BL, corner=6)
add_text(agent_step_x + 6, agent_step_y + 5, 28, 28, [
    ("🤖", {'size': 14, 'name': 'Segoe UI Emoji'})
], align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
# Step title
add_text(agent_step_x + 42, agent_step_y + 6, agent_step_w - 100, 14, [
    ("Agent investigates, fixes & tests", {'size': 9.5, 'bold': True, 'color': HEADER, 'name': FONT})
])
# Time pill on right
pill_w = 50; pill_h = 18
add_rect(agent_step_x + agent_step_w - pill_w - 6, agent_step_y + 8, pill_w, pill_h, PALER_BL, corner=5)
add_text(agent_step_x + agent_step_w - pill_w - 6, agent_step_y + 8, pill_w, pill_h, [
    ("9 min", {'size': 9, 'bold': True, 'color': PRI_DK, 'name': FONT})
], align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)

# Funnel rows
funnel_x = agent_step_x + 12
funnel_y = agent_step_y + 30
funnel_w_full = agent_step_w - 24
funnel_data = [
    ("QA Bug › Investigate", "whole repo",  1.00, (0xBD,0xD7,0xEE), (0x8F,0xAA,0xDC), HEADER),
    ("Diagnose",            "suspect files",0.78, (0x8F,0xAA,0xDC), (0x5B,0x9B,0xD5), WHITE),
    ("Fix",                 "root cause",   0.64, (0x5B,0x9B,0xD5), (0x44,0x72,0xC4), WHITE),
    ("Verify",              "tests pass",   0.50, (0x44,0x72,0xC4), (0x2E,0x5B,0xAC), WHITE),
]
fy = funnel_y
fh = 20
for stage, sub, width_frac, ca, cb, text_color in funnel_data:
    fw = int(funnel_w_full * width_frac)
    fx = funnel_x + (funnel_w_full - fw) // 2
    add_gradient_rect(fx, fy, fw, fh, ca, cb, corner=4, angle=90)
    # stage label (left), sub (right)
    add_text(fx + 10, fy, fw - 20, fh, [
        (stage, {'size': 8.5, 'bold': True, 'color': text_color, 'name': FONT})
    ], anchor=MSO_ANCHOR.MIDDLE)
    add_text(fx + 10, fy, fw - 20, fh, [
        (sub, {'size': 7.5, 'bold': True, 'color': text_color, 'name': FONT})
    ], align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.MIDDLE)
    fy += fh + 2

y = agent_step_y + agent_step_h + 8

# Step 3: dev reviews
y = step_row(X3, y, W3, "📋", "Dev reviews the report", "Reads findings, approves the fix.", "3 min", THEME_AGENT)
# Step 4: approve & ship
y = step_row(X3, y, W3, "✅", "Approve & ship", "Tests already passed in the agent run.", "2 min", THEME_AGENT)

# ============================================================
#  SAVINGS BAR (bottom)
# ============================================================
SAV_TOP = COLS_TOP + COLS_H + 8
SAV_H = 70
SAV_X = PAD_L
SAV_W = SLIDE_W_PX - PAD_L - PAD_R

add_gradient_rect(SAV_X, SAV_TOP, SAV_W, SAV_H,
                  (0x44,0x54,0x6A), (0x44,0x72,0xC4),
                  corner=12, angle=135)

def savings_tile(x, w, label, value_runs, note_runs):
    add_text(x, SAV_TOP + 10, w, 12, [
        (label, {'size': 7.5, 'bold': True, 'color': PALE_BL, 'spacing': 1.5, 'name': FONT})
    ], align=PP_ALIGN.CENTER)
    add_text(x, SAV_TOP + 22, w, 28, value_runs, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.TOP)
    add_text(x, SAV_TOP + 50, w, 16, note_runs, align=PP_ALIGN.CENTER)

# 4 tiles
tile_w = SAV_W / 4
for i, label in enumerate(["COST / BUG: MANUAL", "COST / BUG: CLAUDE CODE", "COST / BUG: RCA AGENT", "NET SAVINGS: RCA AGENT"]):
    if i > 0:
        # vertical divider
        add_rect(SAV_X + int(tile_w * i), SAV_TOP + 12, 1, SAV_H - 24, RGBColor(0x66, 0x82, 0xAE),
                 shape=MSO_SHAPE.RECTANGLE, corner=0)

tile_x0 = SAV_X
tile_x1 = SAV_X + int(tile_w)
tile_x2 = SAV_X + int(tile_w * 2)
tile_x3 = SAV_X + int(tile_w * 3)

savings_tile(tile_x0, int(tile_w), "COST / BUG: MANUAL",
    [("$60.00", {'size': 20, 'bold': True, 'color': WHITE, 'name': FONT})],
    [("75 min × $48/hr", {'size': 8, 'color': PALE_BL, 'name': FONT})])

savings_tile(tile_x1, int(tile_w), "COST / BUG: VIBE CODING",
    [("$36.00", {'size': 20, 'bold': True, 'color': WHITE, 'name': FONT})],
    [("40 min dev + ~$4 AI tokens", {'size': 8, 'color': PALE_BL, 'name': FONT})])

savings_tile(tile_x2, int(tile_w), "COST / BUG: AGENTIC",
    [("$6.00", {'size': 20, 'bold': True, 'color': GOLD, 'name': FONT})],
    [("5 min dev time + ~$2 agent run", {'size': 8, 'color': PALE_BL, 'name': FONT})])

savings_tile(tile_x3, int(tile_w), "NET SAVINGS: AGENTIC",
    [("$30.00", {'size': 20, 'bold': True, 'color': GOLD_DK, 'name': FONT}),
     (" vs Vibe Coding", {'size': 8, 'bold': True, 'color': RGBColor(0xDB,0xE5,0xF1), 'name': FONT})],
    [("$54", {'size': 8, 'bold': True, 'color': GOLD, 'name': FONT}),
     (" vs manual · At 500 bugs/yr → ", {'size': 8, 'color': PALE_BL, 'name': FONT}),
     ("~$15K saved", {'size': 8, 'bold': True, 'color': WHITE, 'name': FONT}),
    ])

# ---------- Save ----------
out = r"c:\MAS_final\rca-mas\docs\three-way-comparison-slide-native-v2.pptx"
prs.save(out)
print(f"Wrote {out}")
