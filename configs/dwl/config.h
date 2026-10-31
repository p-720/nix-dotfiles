/* dwl bar config: waybar palette/font, icon tags */

#define COLOR(hex)    { ((hex >> 24) & 0xFF) / 255.0f, \
                        ((hex >> 16) & 0xFF) / 255.0f, \
                        ((hex >> 8) & 0xFF) / 255.0f, \
                        (hex & 0xFF) / 255.0f }
/* appearance */
static const int sloppyfocus               = 1;
static const int bypass_surface_visibility = 0;
static const unsigned int borderpx         = 2;
static const unsigned int snap             = 32;
static const int showbar                   = 1;
static const int topbar                    = 0; /* waybar was at the bottom */
static const char *fonts[]                 = {
	"ShureTechMono Nerd Font:size=16",
	"Noto Sans M Nerd Font:size=16",
};
static const float rootcolor[]             = COLOR(0x000000ff);
static const float bordercolor[]           = COLOR(0x595959ff);
static const float focuscolor[]            = COLOR(0x33ccffff);
static const float urgentcolor[]           = COLOR(0x7bc275ff);
static const float fullscreen_bg[]         = {0.0f, 0.0f, 0.0f, 1.0f};

static uint32_t colors[][3] = {
	/*               fg          bg          border    */
	[SchemeNorm] = { 0xffffffff, 0x00000080, 0x595959ff },
	[SchemeSel]  = { 0x2a2e38ff, 0x51afefff, 0x33ccffff },
	[SchemeUrg]  = { 0x2a2e38ff, 0x7bc275ff, 0x7bc275ff },
};

/* tagging - TAGCOUNT must be no greater than 31 */
#define TAGCOUNT (12)
static char *tags[] = {
	"\uf120", /* terminal */
	"\uf269", /* browser */
	"\uf075", /* chat */
	"\uf001", /* music */
	"\uf07b", /* files */
	"\uf03d", /* video */
	"\uf0e0", /* mail */
	"\uf1c0", /* database */
	"\uf0c2", /* cloud */
	"\uf013", /* settings */
	"\uf121", /* code */
	"\uf11b", /* games */
};

/* logging */
static int log_level = WLR_ERROR;

static const Rule rules[] = {
	/* app_id                    title                tags mask   isfloating  monitor  scratchkey */
	{ "org.telegram.desktop",    NULL,                1 << 10,    0,          -1,      0 },
	{ "TelegramDesktop",         NULL,                1 << 10,    0,          -1,      0 },
	{ "max",                     NULL,                1 << 11,    0,          -1,      0 },
	{ "calendar.google.com",     NULL,                1 << 9,     0,          -1,      0 },
	{ "steam",                   NULL,                0,          1,          -1,      0 },
	{ "Anki",                    NULL,                0,          1,          -1,      0 },
	{ "org.pulseaudio.pavucontrol", NULL,             0,          1,          -1,      0 },
	{ "blueman-manager",         NULL,                0,          1,          -1,      0 },
	{ "xdg-desktop-portal-gtk",  NULL,                0,          1,          -1,      0 },
	{ "org.kde.kdenlive",        NULL,                0,          1,          -1,      0 },
	{ "Gpick",                   NULL,                0,          1,          -1,      0 },
	{ "chatterino",              NULL,                0,          1,          -1,      0 },
	{ NULL,                      "Picture-in-Picture", 0,         1,          -1,      0 },
	{ NULL,                      "Media viewer",      0,          1,          -1,      0 },
	{ NULL,                      "Library",           0,          1,          -1,      0 },
	/* hyprland special workspaces */
	{ "qbittorrent",             NULL,                0,          1,          -1,      's' },
	{ "peedcrunch",             NULL,                0,          1,          -1,      'c' },
	{ NULL,                      "emacs-todo",        0,          1,          -1,      'n' },
	{ "scratchpad-foot",         NULL,                0,          1,          -1,      'f' },
	{ "brave-chatgpt",           NULL,                0,          1,          -1,      'g' },
	{ "brave-deepseek",          NULL,                0,          1,          -1,      'o' },
	{ "brave-grok",              NULL,                0,          1,          -1,      'u' },
	{ "brave-claude",            NULL,                0,          1,          -1,      'i' },
	{ "brave-aistudio",          NULL,                0,          1,          -1,      'b' },
	{ "brave-open.spotify",      NULL,                0,          1,          -1,      'm' },
};

/* layout(s) */
static const Layout layouts[] = {
	{ "[]=",      tile },
	{ "[M]",      monocle },
	{ "><>",      NULL },
};

/* monitors */
static const MonitorRule monrules[] = {
	{ NULL,       0.70f, 1,      1,    &layouts[0], WL_OUTPUT_TRANSFORM_NORMAL,   -1,  -1 },
};

/* keyboard */
static const struct xkb_rule_names xkb_rules = {
	.layout = "us,ru",
	.options = "grp:alt_shift_toggle",
};

static const int repeat_rate = 25;
static const int repeat_delay = 600;

/* Trackpad */
static const int tap_to_click = 1;
static const int tap_and_drag = 1;
static const int drag_lock = 1;
static const int natural_scrolling = 0;
static const int disable_while_typing = 1;
static const int left_handed = 0;
static const int middle_button_emulation = 0;
static const enum libinput_config_scroll_method scroll_method = LIBINPUT_CONFIG_SCROLL_2FG;
static const enum libinput_config_click_method click_method = LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;
static const uint32_t send_events_mode = LIBINPUT_CONFIG_SEND_EVENTS_ENABLED;
/* hyprland: accel_profile = flat, sensitivity = 0 */
static const enum libinput_config_accel_profile accel_profile = LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT;
static const double accel_speed = 0.0;
static const enum libinput_config_tap_button_map button_map = LIBINPUT_CONFIG_TAP_MAP_LRM;

#define MODKEY WLR_MODIFIER_LOGO

#define TAGKEYS(KEY,TAG) \
	{ MODKEY,                    KEY,            view,            {.ui = 1 << TAG} }, \
	{ MODKEY|WLR_MODIFIER_CTRL,  KEY,            toggleview,      {.ui = 1 << TAG} }, \
	{ MODKEY|WLR_MODIFIER_SHIFT, KEY,            tag,             {.ui = 1 << TAG} }, \
	{ MODKEY|WLR_MODIFIER_CTRL|WLR_MODIFIER_SHIFT,KEY,toggletag,  {.ui = 1 << TAG} }

#define SHCMD(cmd) { .v = (const char*[]){ "/bin/sh", "-c", cmd, NULL } }

static const char *termcmd[] = { "foot", NULL };
static const char *filemgr[] = { "nautilus", NULL };
static const char *menucmd[] = { "sh", "-c", "$HOME/.config/rofi/launchers/colorful/launcher.sh", NULL };
static const char *pomotask[] = { "sh", "-c", "$HOME/.config/rofi/launchers/colorful/pomotask.sh", NULL };
static const char *lightctl[] = { "sh", "-c", "$HOME/.config/polybar/light_control.sh", NULL };
static const char *lockcmd[] = { "swaylock", "-c", "000000", NULL };

static const char *scratch_default[] = { "s", "qbittorrent", NULL };
static const char *scratch_emacs[] = { "n", "emacsclient", "-c", "-F", "((name . \"emacs-todo\"))", NULL };
static const char *scratch_speedcrunch[] = { "c", "speedcrunch", NULL };
static const char *scratch_foot[] = { "f", "foot", "-a", "scratchpad-foot", "-T", "scratchpad-foot", NULL };
static const char *scratch_openai[] = { "g", "brave", "--app=https://chatgpt.com/", NULL };
static const char *scratch_deepseek[] = { "o", "brave", "--app=https://chat.deepseek.com/", NULL };
static const char *scratch_grok[] = { "u", "brave", "--app=https://grok.com/", NULL };
static const char *scratch_otherai[] = { "i", "brave", "--app=https://claude.ai/", NULL };
static const char *scratch_gemini[] = { "b", "brave", "--app=https://aistudio.google.com/prompts/new_chat", NULL };
static const char *scratch_music[] = { "m", "brave", "--app=https://open.spotify.com/", NULL };

static const Key keys[] = {
	/* modifier                  key                       function          argument */
	{ MODKEY,                    XKB_KEY_Return,           spawn,            {.v = termcmd} },
	{ MODKEY,                    XKB_KEY_q,                spawn,            {.v = termcmd} },
	{ MODKEY,                    XKB_KEY_x,                killclient,       {0} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_q,                quit,             {0} },
	{ MODKEY,                    XKB_KEY_e,                spawn,            {.v = filemgr} },
	{ MODKEY,                    XKB_KEY_t,                togglefloating,   {0} },
	{ MODKEY,                    XKB_KEY_f,                togglefullscreen, {0} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_b,                togglebar,        {0} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_l,                spawn,            {.v = lockcmd} },
	{ MODKEY,                    XKB_KEY_d,                spawn,            {.v = menucmd} },
	{ MODKEY,                    XKB_KEY_p,                spawn,            {.v = pomotask} },
	{ MODKEY,                    XKB_KEY_z,                spawn,            {.v = pomotask} },
	{ MODKEY,                    XKB_KEY_bracketright,     spawn,            {.v = lightctl} },
	{ MODKEY,                    XKB_KEY_Tab,              setlayout,        {0} },
	/* hyprland special workspaces */
	{ MODKEY,                    XKB_KEY_s,                togglescratch,    {.v = scratch_default} },
	{ MODKEY,                    XKB_KEY_n,                togglescratch,    {.v = scratch_emacs} },
	{ MODKEY,                    XKB_KEY_c,                togglescratch,    {.v = scratch_speedcrunch} },
	{ 0,                         XKB_KEY_F12,              togglescratch,    {.v = scratch_foot} },
	{ MODKEY,                    XKB_KEY_g,                togglescratch,    {.v = scratch_openai} },
	{ MODKEY,                    XKB_KEY_o,                togglescratch,    {.v = scratch_deepseek} },
	{ MODKEY,                    XKB_KEY_u,                togglescratch,    {.v = scratch_grok} },
	{ MODKEY,                    XKB_KEY_i,                togglescratch,    {.v = scratch_otherai} },
	{ MODKEY,                    XKB_KEY_b,                togglescratch,    {.v = scratch_gemini} },
	{ MODKEY,                    XKB_KEY_m,                togglescratch,    {.v = scratch_music} },
	/* focus */
	{ MODKEY,                    XKB_KEY_h,                focusstack,       {.i = -1} },
	{ MODKEY,                    XKB_KEY_k,                focusstack,       {.i = -1} },
	{ MODKEY,                    XKB_KEY_l,                focusstack,       {.i = +1} },
	{ MODKEY,                    XKB_KEY_j,                focusstack,       {.i = +1} },
	/* resize master / stack counts */
	{ MODKEY|WLR_MODIFIER_CTRL,  XKB_KEY_h,                setmfact,         {.f = -0.05f} },
	{ MODKEY|WLR_MODIFIER_CTRL,  XKB_KEY_l,                setmfact,         {.f = +0.05f} },
	{ MODKEY|WLR_MODIFIER_CTRL,  XKB_KEY_k,                incnmaster,       {.i = -1} },
	{ MODKEY|WLR_MODIFIER_CTRL,  XKB_KEY_j,                incnmaster,       {.i = +1} },
	/* monitors */
	{ MODKEY,                    XKB_KEY_comma,            focusmon,         {.i = WLR_DIRECTION_LEFT} },
	{ MODKEY,                    XKB_KEY_period,           focusmon,         {.i = WLR_DIRECTION_RIGHT} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_comma,            tagmon,           {.i = WLR_DIRECTION_LEFT} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_period,           tagmon,           {.i = WLR_DIRECTION_RIGHT} },
	TAGKEYS(                     XKB_KEY_1,                0),
	TAGKEYS(                     XKB_KEY_2,                1),
	TAGKEYS(                     XKB_KEY_3,                2),
	TAGKEYS(                     XKB_KEY_4,                3),
	TAGKEYS(                     XKB_KEY_5,                4),
	TAGKEYS(                     XKB_KEY_6,                5),
	TAGKEYS(                     XKB_KEY_7,                6),
	TAGKEYS(                     XKB_KEY_8,                7),
	TAGKEYS(                     XKB_KEY_9,                8),
	TAGKEYS(                     XKB_KEY_0,                9),
	TAGKEYS(                     XKB_KEY_minus,            10),
	TAGKEYS(                     XKB_KEY_equal,            11),
	/* media */
	{ 0, XKB_KEY_XF86AudioRaiseVolume, spawn, SHCMD("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+") },
	{ 0, XKB_KEY_XF86AudioLowerVolume, spawn, SHCMD("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") },
	{ 0, XKB_KEY_XF86AudioMute,        spawn, SHCMD("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle") },
	{ 0, XKB_KEY_XF86Search,           spawn, SHCMD("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle") },
	{ 0, XKB_KEY_XF86AudioMicMute,     spawn, SHCMD("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle") },
	{ 0, XKB_KEY_XF86MonBrightnessUp,  spawn, SHCMD("brightnessctl s 10%+") },
	{ 0, XKB_KEY_XF86MonBrightnessDown,spawn, SHCMD("brightnessctl s 10%-") },
	{ 0, XKB_KEY_XF86AudioNext,        spawn, SHCMD("playerctl next") },
	{ 0, XKB_KEY_XF86AudioPause,       spawn, SHCMD("playerctl play-pause") },
	{ 0, XKB_KEY_XF86AudioPlay,        spawn, SHCMD("playerctl play-pause") },
	{ 0, XKB_KEY_XF86AudioPrev,        spawn, SHCMD("playerctl previous") },
	/* screenshots and recording */
	{ 0, XKB_KEY_Print,                spawn, SHCMD("flameshot gui --delay=1000") },
	{ WLR_MODIFIER_SHIFT, XKB_KEY_Print, spawn, SHCMD("grim - | wl-copy") },
	{ WLR_MODIFIER_CTRL,  XKB_KEY_Print, spawn, SHCMD("grim -g \"$(slurp)\" - | wl-copy") },
	{ 0, XKB_KEY_Scroll_Lock,          spawn, SHCMD("fish -c 'record_screen_replay_sound'") },
	{ WLR_MODIFIER_SHIFT, XKB_KEY_Scroll_Lock, spawn, SHCMD("fish -c 'trim_last_replay'") },
	{ WLR_MODIFIER_CTRL,  XKB_KEY_Scroll_Lock, spawn, SHCMD("fish -c 'copy_last_replay'") },
	{ WLR_MODIFIER_CTRL|WLR_MODIFIER_SHIFT, XKB_KEY_Scroll_Lock, spawn, SHCMD("fish -c 'record_screen_replay_sound_stop'") },
	{ 0, XKB_KEY_Pause,                spawn, SHCMD("fish -c 'record'") },
	{ WLR_MODIFIER_SHIFT, XKB_KEY_Pause, spawn, SHCMD("fish -c 'trim_video_from_clipboard'") },
	{ WLR_MODIFIER_CTRL|WLR_MODIFIER_SHIFT, XKB_KEY_u, spawn, SHCMD("fish -c 'shorten-url'") },
	{ WLR_MODIFIER_CTRL|WLR_MODIFIER_ALT,XKB_KEY_BackSpace, quit, {0} },
#define CHVT(n) { WLR_MODIFIER_CTRL|WLR_MODIFIER_ALT,XKB_KEY_F##n, chvt, {.ui = (n)} }
	CHVT(1), CHVT(2), CHVT(3), CHVT(4), CHVT(5), CHVT(6),
	CHVT(7), CHVT(8), CHVT(9), CHVT(10), CHVT(11), CHVT(12),
};

static const Button buttons[] = {
	/* click                modifier                  button      function          argument */
	{ ClkTagBar,            0,                        BTN_LEFT,   view,             {0} },
	{ ClkTagBar,            0,                        BTN_RIGHT,  toggleview,       {0} },
	{ ClkTagBar,            MODKEY,                   BTN_LEFT,   tag,              {0} },
	{ ClkTagBar,            MODKEY,                   BTN_RIGHT,  toggletag,        {0} },
	{ ClkLtSymbol,          0,                        BTN_LEFT,   setlayout,        {.v = &layouts[0]} },
	{ ClkLtSymbol,          0,                        BTN_RIGHT,  setlayout,        {.v = &layouts[2]} },
	{ ClkTitle,             0,                        BTN_MIDDLE, zoom,             {0} },
	{ ClkStatus,            0,                        BTN_MIDDLE, spawn,            {.v = termcmd} },
	{ ClkClient,            MODKEY,                   BTN_LEFT,   moveresize,       {.ui = CurMove} },
	{ ClkClient,            MODKEY,                   BTN_MIDDLE, togglefloating,   {0} },
	{ ClkClient,            MODKEY,                   BTN_RIGHT,  moveresize,       {.ui = CurResize} },
};

static const Axis axes[] = {
	{ MODKEY, AxisUp,   spawn, SHCMD("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+") },
	{ MODKEY, AxisDown, spawn, SHCMD("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") },
};
