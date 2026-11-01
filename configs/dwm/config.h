#include <X11/XF86keysym.h>
#include <limits.h>
/* See LICENSE file for copyright and license details. */

/* appearance */
static const unsigned int borderpx  = 2;        /* border pixel of windows */
static const unsigned int snap      = 32;       /* snap pixel */
static const int showbar            = 1;        /* 0 means no bar */
static const int topbar             = 0;        /* 0 means bottom bar */
static const int usealtbar          = 1;        /* taffybar is the bar */
static const char *altbarclass      = "Taffybar";
static const char *altbarcmd        = "";
static const char *fonts[]          = {
	"ShureTechMono Nerd Font:size=12",
	"Noto Sans M Nerd Font:size=12",
};
static const char dmenufont[]       = "ShureTechMono Nerd Font:size=12";
static const char col_gray1[]       = "#000000";
static const char col_gray2[]       = "#595959";
static const char col_gray3[]       = "#ffffff";
static const char col_gray4[]       = "#2a2e38";
static const char col_cyan[]        = "#51afef";
static const char *colors[][3]      = {
	/*               fg         bg         border   */
	[SchemeNorm] = { col_gray3, col_gray1, col_gray2 },
	[SchemeSel]  = { col_gray4, col_cyan,  "#33ccff" },
};

/* tagging */
static const char *tags[] = {
	"1", "2", "3", "4", "5", "6",
	"7", "8", "9", "10", "11", "12",
	"alacritty", "openai", "deepseek", "grok", "otherai", "gemini", "music", "speedcrunch", "emacs",
};
/* tags 1-6 start on monitor 0, 7-12 on monitor 1; movetag updates this */
static int tagowner[LENGTH(tags)] = {
	0, 0, 0, 0, 0, 0,
	1, 1, 1, 1, 1, 1,
	0, 0, 0, 0, 0, 0, 0, 0, 0
};

static const Rule rules[] = {
	/* class                     instance  title       tags mask  isfloating  monitor */
	{ "Telegram",                NULL,     NULL,       1 << 10,   0,          -1 },
	{ "TelegramDesktop",         NULL,     NULL,       1 << 10,   0,          -1 },
	{ "org.telegram.desktop",    NULL,     NULL,       1 << 10,   0,          -1 },
	{ "max",                     NULL,     NULL,       1 << 11,   0,          -1 },
	{ "Firefox",                 NULL,     NULL,       0,         0,          -1 },
	{ "Brave-browser",           NULL,     NULL,       0,         0,          -1 },
	{ "foot",                    NULL,     NULL,       0,         0,          -1 },
	{ "Alacritty",               NULL,     NULL,       0,         0,          -1 },
	{ "qBittorrent",             NULL,     NULL,       0,         0,          -1 },
	{ "SpeedCrunch",             NULL,     NULL,       0,         0,          -1 },
	{ "Emacs",                   NULL,     NULL,       0,         0,          -1 },
	{ "Spotify",                 NULL,     NULL,       0,         0,          -1 },
	{ "discord",                 NULL,     NULL,       0,         0,          -1 },
	{ "chatterino",              NULL,     NULL,       0,         0,          -1 },
	{ "Steam",                   NULL,     NULL,       0,         1,          -1 },
	{ "Anki",                    NULL,     NULL,       0,         1,          -1 },
	{ "Pavucontrol",             NULL,     NULL,       0,         1,          -1 },
	{ "blueman-manager",         NULL,     NULL,       0,         1,          -1 },
	{ "xdg-desktop-portal-gtk",  NULL,     NULL,       0,         1,          -1 },
	{ "Gpick",                   NULL,     NULL,       0,         1,          -1 },
	{ "Gimp",                    NULL,     NULL,       0,         1,          -1 },
	{ "Kdenlive",                NULL,     NULL,       0,         1,          -1 },
	{ "flameshot",               NULL,     NULL,       0,         1,          -1 },
	{ "Yad",                     NULL,     NULL,       0,         1,          -1 },
	{ "guake",                   NULL,     NULL,       0,         1,          -1 },
	{ NULL,                      NULL,     "Picture-in-Picture", 0, 1,       -1 },
	{ NULL,                      NULL,     "Media viewer",      0, 1,       -1 },
	{ NULL,                      NULL,     "Library",           0, 1,       -1 },
};

/* hyprland workspace 11: firefox 20% | telegram golden ratio | rest stacked */
static void
telegram(Monitor *m)
{
	Client *c, *ff = NULL, *tg = NULL, *others[64];
	XClassHint ch;
	int n = 0, i, x, w, yy, rh, fw, tw;

	for (c = m->clients; c; c = c->next) {
		if (!ISVISIBLE(c))
			continue;
		ch.res_class = NULL;
		ch.res_name = NULL;
		if (XGetClassHint(dpy, c->win, &ch)) {
			if (!ff && ch.res_class && strstr(ch.res_class, "irefox"))
				ff = c;
			else if (!tg && ch.res_class && strstr(ch.res_class, "elegram"))
				tg = c;
			else if (n < 64)
				others[n++] = c;
			if (ch.res_class)
				XFree(ch.res_class);
			if (ch.res_name)
				XFree(ch.res_name);
		} else if (n < 64) {
			others[n++] = c;
		}
	}

	if (!ff && !tg) {
		tile(m);
		return;
	}

	fw = ff ? (int)(m->ww * 0.20) : 0;
	if (ff) {
		resize(ff, m->wx, m->wy, fw, m->wh, 1);
	}

	x = m->wx + fw;
	w = m->ww - fw;
	if (tg) {
		if (n > 0) {
			tw = (int)(w * 0.618);
			resize(tg, x, m->wy, tw, m->wh, 1);
			x += tw;
			w -= tw;
		} else {
			resize(tg, x, m->wy, w, m->wh, 1);
			w = 0;
		}
	}

	yy = m->wy;
	for (i = 0; i < n && w > 0; i++) {
		rh = (m->wy + m->wh - yy) / (n - i);
		resize(others[i], x, yy, w, rh, 1);
		yy += rh;
	}
	restack(m);
}

/* layout(s) */
static const float mfact     = 0.70; /* factor of master area size [0.05..0.95] */
static const int nmaster     = 1;    /* number of clients in master area */
static const int resizehints = 1;    /* 1 means respect size hints in tiled resizals */
static const int lockfullscreen = 1; /* 1 will force focus on the fullscreen window */

static const Layout layouts[] = {
	/* symbol     arrange function */
	{ "[]=",      tile },    /* first entry is default */
	{ "><>",      NULL },    /* no layout function means floating behavior */
	{ "[M]",      monocle },
	{ "ff-tg",    telegram },
};

static Monitor *
monitorbyindex(int index)
{
	Monitor *m;

	for (m = mons; m; m = m->next)
		if (m->num == index)
			return m;
	return NULL;
}

static Monitor *
tagmonitor(unsigned int mask)
{
	Monitor *m;
	int idx = -1, i;

	if (!mask || (mask & (mask - 1)) != 0)
		return selmon;
	for (i = 0; i < LENGTH(tags); i++)
		if (mask & (1 << i)) {
			idx = i;
			break;
		}
	if (idx < 0)
		return selmon;
	m = monitorbyindex(tagowner[idx]);
	return m ? m : selmon;
}

/* hyprland ALT+SUPER+1/0/2/9/minus: move workspace to monitor */
static void
movetag(const Arg *arg)
{
	Monitor *m = monitorbyindex(arg->i);
	unsigned int tag;
	Client *c, *next;
	int idx = -1, i;

	if (!m || m == selmon)
		return;
	tag = selmon->tagset[selmon->seltags];
	for (i = 0; i < LENGTH(tags); i++)
		if (tag & (1 << i)) {
			idx = i;
			break;
		}
	if (idx < 0)
		return;

	tagowner[idx] = arg->i;
	m->seltags ^= 1;
	m->tagset[m->seltags] = tag;

	for (c = selmon->clients; c; c = next) {
		next = c->next;
		if (!(c->tags & tag))
			continue;
		sendmon(c, m);
		c->tags = tag;
	}

	selmon = m;
	focus(NULL);
	updatecurrentdesktop();
	arrange(NULL);
}

static void
warppointer(Client *c)
{
	int x = c ? c->x + c->w / 2 : selmon->mx + selmon->mw / 2;
	int y = c ? c->y + c->h / 2 : selmon->my + selmon->mh / 2;

	XWarpPointer(dpy, None, root, 0, 0, 0, 0, x, y);
	XFlush(dpy);
}

/* hyprland special apps; tags 13-21 are hidden scratch tags */
static const char *special_alacritty[] = { "alacritty", NULL };
static const char *special_openai[] = { "firefox-pwa", "https://chatgpt.com/", NULL };
static const char *special_deepseek[] = { "firefox-pwa", "https://chat.deepseek.com/", NULL };
static const char *special_grok[] = { "firefox-pwa", "https://grok.com/", NULL };
static const char *special_otherai[] = { "firefox-pwa", "https://claude.ai/", NULL };
static const char *special_gemini[] = { "firefox", "--new-window", "https://gemini.google.com", NULL };
static const char *special_music[] = { "firefox-pwa", "https://open.spotify.com/", NULL };
static const char *special_speedcrunch[] = { "speedcrunch", NULL };
static const char *special_emacs[] = { "emacs", NULL };
static const char **specialcmds[] = {
	special_alacritty, special_openai, special_deepseek, special_grok,
	special_otherai, special_gemini, special_music, special_speedcrunch,
	special_emacs
};
static const char *telegram_ffcmd[] = { "firefox-pwa", "https://ug.kyrgyzstan.kg/pomotask/", NULL };
static const char *telegram_tgcmd[] = {
	"sh", "-c", "env GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb WEBKIT_DISABLE_DMABUF_RENDERER=1 Telegram", NULL
};

static int
hasclass(Monitor *m, unsigned int mask, const char *needle)
{
	Client *c;
	XClassHint ch;

	for (c = m->clients; c; c = c->next) {
		if (!(c->tags & mask))
			continue;
		ch.res_class = ch.res_name = NULL;
		if (XGetClassHint(dpy, c->win, &ch)) {
			int found = (ch.res_class && strstr(ch.res_class, needle))
				|| (ch.res_name && strstr(ch.res_name, needle));
			if (ch.res_class)
				XFree(ch.res_class);
			if (ch.res_name)
				XFree(ch.res_name);
			if (found)
				return 1;
		}
	}
	return 0;
}

static void
viewtag(const Arg *arg)
{
	Monitor *m = tagmonitor(arg->ui), *prev = selmon;

	if (m != selmon) {
		unfocus(selmon->sel, 0);
		selmon = m;
		focus(NULL);
	}

	view(arg);
	if (!selmon)
		return;
	if (arg->ui & (1 << 10))
		selmon->lt[selmon->sellt] = &layouts[3];
	else if (selmon->lt[selmon->sellt] == &layouts[3])
		selmon->lt[selmon->sellt] = &layouts[0];
	arrange(selmon);
	/* workspace 11: hyprland launches the missing Telegram/Firefox pair */
	if (arg->ui & (1 << 10)) {
		if (!hasclass(selmon, 1 << 10, "irefox"))
			spawn(&(Arg){ .v = telegram_ffcmd });
		if (!hasclass(selmon, 1 << 10, "elegram"))
			spawn(&(Arg){ .v = telegram_tgcmd });
	}
	/* follow only when the workspace moved to another monitor */
	if (selmon != prev)
		warppointer(selmon->sel);
}

static unsigned int specialprev[LENGTH(tags)];

static void
togglespecial(const Arg *arg)
{
	unsigned int mask;
	int idx = arg->i;
	Monitor *m = selmon;
	Client *c;
	Arg a;

	if (!m || idx < 12 || idx >= LENGTH(tags))
		return;
	mask = 1u << idx;
	if (m->tagset[m->seltags] & mask) {
		a.ui = specialprev[idx] ? specialprev[idx] : 1u;
		specialprev[idx] = 0;
		viewtag(&a);
		return;
	}
	specialprev[idx] = m->tagset[m->seltags];
	tagowner[idx] = m->num;
	a.ui = mask;
	viewtag(&a);
	for (c = m->clients; c; c = c->next)
		if (c->tags & mask)
			return;
	spawn(&(Arg){ .v = specialcmds[idx - 12] });
}

/* move the focused window to the target tag and follow it */
static void
tagto(const Arg *arg)
{
	Monitor *m = tagmonitor(arg->ui);
	Client *c = selmon->sel;

	if (!c)
		return;
	if (m != selmon)
		sendmon(c, m);
	c->tags = arg->ui;
	updateclientlist();
	viewtag(arg);
}

/* workspace 12: start firefox with max.ru when it is empty */
static void
togglefullscreenf(const Arg *arg)
{
	if (selmon->sel)
		setfullscreen(selmon->sel, !selmon->sel->isfullscreen);
}

static void
togglefakefullscreen(const Arg *arg)
{
	Client *c = selmon->sel;
	Atom actualType, fullscreen, state, *cur, *next;
	int actualFormat, has = 0, i, n = 0, m = 0;
	unsigned long nitems, bytesAfter;
	unsigned char *data = NULL;

	if (!c)
		return;
	fullscreen = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
	state = XInternAtom(dpy, "_NET_WM_STATE", False);
	if (XGetWindowProperty(dpy, c->win, state, 0, 1024, False, XA_ATOM,
			&actualType, &actualFormat, &nitems, &bytesAfter, &data) == Success && data) {
		cur = (Atom *)data;
		n = nitems;
		for (i = 0; i < n; i++)
			if (cur[i] == fullscreen)
				has = 1;
	}
	next = ecalloc(n + 1, sizeof(Atom));
	for (i = 0; i < n; i++)
		if (cur[i] != fullscreen)
			next[m++] = cur[i];
	if (!has)
		next[m++] = fullscreen;
	if (m)
		XChangeProperty(dpy, c->win, state, XA_ATOM, 32, PropModeReplace,
			(unsigned char *)next, m);
	else
		XDeleteProperty(dpy, c->win, state);
	free(next);
	if (data)
		XFree(data);
	XFlush(dpy);
}

static const char *maxcmd[] = {
	"firefox", "--new-window", "https://web.max.ru/", NULL,
};

static void
viewmax(const Arg *arg)
{
	Client *c;
	int empty = 1;

	for (c = selmon->clients; c; c = c->next)
		if (c->tags & (1 << 11)) {
			empty = 0;
			break;
		}

	viewtag(arg);
	if (empty)
		spawn(&(Arg){ .v = maxcmd });
}

enum { DirLeft, DirRight, DirUp, DirDown };

static long
dist2(int x1, int y1, int x2, int y2)
{
	long dx = x1 - x2;
	long dy = y1 - y2;
	return dx * dx + dy * dy;
}

static Monitor *
adjmon(int dir)
{
	Monitor *m, *best = NULL;
	long bestdist = LONG_MAX;
	int sx = selmon->mx, sy = selmon->my;
	int sw = selmon->mw, sh = selmon->mh;
	int cx = sx + sw / 2, cy = sy + sh / 2;

	for (m = mons; m; m = m->next) {
		long d;
		if (m == selmon)
			continue;
		if (dir == DirLeft && m->mx + m->mw > sx)
			continue;
		if (dir == DirRight && m->mx < sx + sw)
			continue;
		if (dir == DirUp && m->my + m->mh > sy)
			continue;
		if (dir == DirDown && m->my < sy + sh)
			continue;
		d = dist2(cx, cy, m->mx + m->mw / 2, m->my + m->mh / 2);
		if (d < bestdist) {
			bestdist = d;
			best = m;
		}
	}
	return best;
}

static void
focusdir(const Arg *arg)
{
	Client *c = selmon->sel, *t, *best = NULL;
	Monitor *m;
	long bestdist = LONG_MAX;
	int cx, cy, tx, ty;
	int dir = arg->i;

	if (!c) {
		focus(NULL);
		return;
	}
	cx = c->x + c->w / 2;
	cy = c->y + c->h / 2;
	for (t = selmon->clients; t; t = t->next) {
		long d;
		if (t == c || !ISVISIBLE(t))
			continue;
		tx = t->x + t->w / 2;
		ty = t->y + t->h / 2;
		if (dir == DirLeft && tx >= cx)
			continue;
		if (dir == DirRight && tx <= cx)
			continue;
		if (dir == DirUp && ty >= cy)
			continue;
		if (dir == DirDown && ty <= cy)
			continue;
		d = dist2(cx, cy, tx, ty);
		if (d < bestdist) {
			bestdist = d;
			best = t;
		}
	}
	if (best) {
		focus(best);
		warppointer(best);
		return;
	}
	if ((m = adjmon(dir))) {
		unfocus(selmon->sel, 0);
		selmon = m;
		focus(NULL);
		updatecurrentdesktop();
		if (selmon->sel)
			warppointer(selmon->sel);
	}
}

static void
swapclients(Client *a, Client *b)
{
	Client **pa, **pb, *na, *nb;

	if (!a || !b || a == b || a->mon != b->mon)
		return;
	for (pa = &a->mon->clients; *pa && *pa != a; pa = &(*pa)->next);
	for (pb = &a->mon->clients; *pb && *pb != b; pb = &(*pb)->next);
	if (*pa != a || *pb != b)
		return;
	na = a->next;
	nb = b->next;
	if (na == b) {
		*pa = b;
		b->next = a;
		a->next = nb;
	} else if (nb == a) {
		*pb = a;
		a->next = b;
		b->next = na;
	} else {
		*pa = b;
		b->next = na;
		*pb = a;
		a->next = nb;
	}
	arrange(a->mon);
}

static void
movedir(const Arg *arg)
{
	Client *c = selmon->sel, *t, *best = NULL;
	Monitor *m;
	long bestdist = LONG_MAX;
	int cx, cy, tx, ty;
	int dir = arg->i;

	if (!c)
		return;
	cx = c->x + c->w / 2;
	cy = c->y + c->h / 2;
	for (t = selmon->clients; t; t = t->next) {
		long d;
		if (t == c || !ISVISIBLE(t) || t->isfloating)
			continue;
		tx = t->x + t->w / 2;
		ty = t->y + t->h / 2;
		if (dir == DirLeft && tx >= cx)
			continue;
		if (dir == DirRight && tx <= cx)
			continue;
		if (dir == DirUp && ty >= cy)
			continue;
		if (dir == DirDown && ty <= cy)
			continue;
		d = dist2(cx, cy, tx, ty);
		if (d < bestdist) {
			bestdist = d;
			best = t;
		}
	}
	if (best) {
		swapclients(c, best);
		focus(c);
		return;
	}
	if ((m = adjmon(dir))) {
		sendmon(c, m);
		focus(NULL);
	}
}

/* key definitions */
#define MODKEY Mod4Mask
#define TAGKEYS(KEY,TAG) \
	{ MODKEY,                       KEY,      viewtag,        {.ui = 1 << TAG} }, \
	{ MODKEY|ControlMask,           KEY,      toggleview,     {.ui = 1 << TAG} }, \
	{ MODKEY|ShiftMask,             KEY,      tagto,          {.ui = 1 << TAG} }, \
	{ MODKEY|ControlMask|ShiftMask, KEY,      toggletag,      {.ui = 1 << TAG} }

/* helper for spawning shell commands */
#define SHCMD(cmd) { .v = (const char*[]){ "/bin/sh", "-c", cmd, NULL } }

static const char *termcmd[]   = { "foot", NULL };
static const char *filemgr[]   = { "nautilus", NULL };
static char dmenumon[2] = "0";
static const char *dmenucmd[]  = { "sh", "-c", "$HOME/.config/rofi/launchers/colorful/launcher.sh \"$1\"", "sh", dmenumon, NULL };
static const char *pomotask[]  = { "sh", "-c", "$HOME/.config/rofi/launchers/colorful/pomotask.sh", NULL };
static const char *lightctl[]  = { "sh", "-c", "$HOME/.config/polybar/light_control.sh", NULL };
static const char *lockcmd[]   = { "i3lock", "-c", "000000", NULL };

static const Key keys[] = {
	/* modifier                     key                       function        argument */
	{ MODKEY,                       XK_Return,           spawn,          {.v = termcmd} },
	{ MODKEY,                       XK_q,                spawn,          {.v = termcmd} },
	{ MODKEY,                       XK_x,                killclient,     {0} },
	{ MODKEY|ShiftMask,             XK_q,                quit,           {0} },
	{ MODKEY,                       XK_e,                spawn,          {.v = filemgr} },
	{ MODKEY,                       XK_t,                togglefloating, {0} },
	{ MODKEY,                       XK_f,                togglefullscreenf, {0} },
	{ MODKEY|ShiftMask,             XK_f,                togglefakefullscreen, {0} },
	{ MODKEY|ShiftMask,             XK_l,                spawn,          {.v = lockcmd} },
	{ MODKEY,                       XK_d,                spawn,          {.v = dmenucmd} },
	{ MODKEY,                       XK_p,                spawn,          {.v = pomotask} },
	{ MODKEY,                       XK_z,                spawn,          {.v = pomotask} },
	{ MODKEY,                       XK_bracketright,     spawn,          {.v = lightctl} },
	{ MODKEY|ShiftMask,             XK_b,                togglebar,      {0} },
	{ MODKEY,                       XK_Tab,              setlayout,      {0} },
	{ MODKEY,                       XK_space,            setlayout,      {0} },
	{ MODKEY|ShiftMask,             XK_Return,           zoom,           {0} },
	/* focus / resize */
	/* directional focus, crossing monitor edges like hyprland */
	{ MODKEY,                       XK_h,                focusdir,       {.i = DirLeft} },
	{ MODKEY,                       XK_l,                focusdir,       {.i = DirRight} },
	{ MODKEY,                       XK_k,                focusdir,       {.i = DirUp} },
	{ MODKEY,                       XK_j,                focusdir,       {.i = DirDown} },
	{ MODKEY|ShiftMask,             XK_i,                incnmaster,     {.i = +1} },
	{ MODKEY,                       XK_a,                incnmaster,     {.i = -1} },
	/* directional window move, swapping clients or crossing monitors */
	{ MODKEY|Mod1Mask,              XK_h,                movedir,        {.i = DirLeft} },
	{ MODKEY|Mod1Mask,              XK_l,                movedir,        {.i = DirRight} },
	{ MODKEY|Mod1Mask,              XK_k,                movedir,        {.i = DirUp} },
	{ MODKEY|Mod1Mask,              XK_j,                movedir,        {.i = DirDown} },
	/* monitors: each monitor keeps its own tag set */
	TAGKEYS(                        XK_1,                0),
	TAGKEYS(                        XK_2,                1),
	TAGKEYS(                        XK_3,                2),
	TAGKEYS(                        XK_4,                3),
	TAGKEYS(                        XK_5,                4),
	TAGKEYS(                        XK_6,                5),
	TAGKEYS(                        XK_7,                6),
	TAGKEYS(                        XK_8,                7),
	TAGKEYS(                        XK_9,                8),
	TAGKEYS(                        XK_0,                9),
	TAGKEYS(                        XK_minus,            10),
	{ MODKEY,                       XK_equal,            viewmax,        {.ui = 1 << 11} },
	{ MODKEY|ControlMask,           XK_equal,            toggleview,     {.ui = 1 << 11} },
	{ MODKEY|ShiftMask,             XK_equal,            tagto,          {.ui = 1 << 11} },
	{ MODKEY|ControlMask|ShiftMask, XK_equal,            toggletag,      {.ui = 1 << 11} },
	/* hyprland special workspaces */
	{ 0,                            XK_F12,              togglespecial,  {.i = 12} },
	{ MODKEY,                       XK_g,                togglespecial,  {.i = 13} },
	{ MODKEY,                       XK_o,                togglespecial,  {.i = 14} },
	{ MODKEY,                       XK_u,                togglespecial,  {.i = 15} },
	{ MODKEY,                       XK_i,                togglespecial,  {.i = 16} },
	{ MODKEY,                       XK_b,                togglespecial,  {.i = 17} },
	{ MODKEY,                       XK_m,                togglespecial,  {.i = 18} },
	{ MODKEY,                       XK_c,                togglespecial,  {.i = 19} },
	{ MODKEY,                       XK_n,                togglespecial,  {.i = 20} },
	/* hyprland ALT+SUPER: move workspace to monitor */
	{ MODKEY|Mod1Mask,              XK_1,                movetag,        {.i = 0} },
	{ MODKEY|Mod1Mask,              XK_0,                movetag,        {.i = 0} },
	{ MODKEY|Mod1Mask,              XK_2,                movetag,        {.i = 1} },
	{ MODKEY|Mod1Mask,              XK_9,                movetag,        {.i = 1} },
	{ MODKEY|Mod1Mask,              XK_minus,            movetag,        {.i = 2} },
	/* media */
	{ 0, XF86XK_AudioRaiseVolume, spawn, SHCMD("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+") },
	{ 0, XF86XK_AudioLowerVolume, spawn, SHCMD("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") },
	{ 0, XF86XK_AudioMute,        spawn, SHCMD("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle") },
	{ 0, XF86XK_AudioMicMute,     spawn, SHCMD("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle") },
	{ 0, XF86XK_MonBrightnessUp,  spawn, SHCMD("brightnessctl s 10%+") },
	{ 0, XF86XK_MonBrightnessDown,spawn, SHCMD("brightnessctl s 10%-") },
	{ 0, XF86XK_AudioNext,        spawn, SHCMD("playerctl next") },
	{ 0, XF86XK_AudioPause,       spawn, SHCMD("playerctl play-pause") },
	{ 0, XF86XK_AudioPlay,        spawn, SHCMD("playerctl play-pause") },
	{ 0, XF86XK_AudioPrev,        spawn, SHCMD("playerctl previous") },
	/* screenshots and recording */
	{ 0, XK_Print,                spawn, SHCMD("flameshot gui --delay=1000") },
	{ ControlMask, XK_Print,      spawn, SHCMD("fish -c 'flameshot full -c'") },
	{ ShiftMask, XK_Print,        spawn, SHCMD("fish -c 'flameshot_screen'") },
	{ ControlMask|ShiftMask, XK_Print, spawn, SHCMD("sh -c '~/.config/i3/screenshot_window.sh activewindow'") },
	{ 0, XK_Scroll_Lock,          spawn, SHCMD("fish -c 'record_screen_replay_sound'") },
	{ ShiftMask, XK_Scroll_Lock,  spawn, SHCMD("fish -c 'trim_last_replay'") },
	{ ControlMask, XK_Scroll_Lock, spawn, SHCMD("fish -c 'copy_last_replay'") },
	{ ControlMask|ShiftMask, XK_Scroll_Lock, spawn, SHCMD("fish -c 'record_screen_replay_sound_stop'") },
	{ 0, XK_Pause,                spawn, SHCMD("fish -c 'record'") },
	{ ShiftMask, XK_Pause,        spawn, SHCMD("fish -c 'trim_video_from_clipboard'") },
	{ ControlMask|ShiftMask, XK_u, spawn, SHCMD("fish -c 'shorten-url'") },
	/* Ctrl-Alt-Backspace */
	{ ControlMask|Mod1Mask, XK_BackSpace, quit, {0} },
};

/* button definitions */
static const Button buttons[] = {
	/* click                event mask  button   function        argument */
	{ ClkLtSymbol,          0,          Button1, setlayout,      {0} },
	{ ClkLtSymbol,          0,          Button3, setlayout,      {.v = &layouts[2]} },
	{ ClkWinTitle,          0,          Button2, zoom,           {0} },
	{ ClkStatusText,        0,          Button2, spawn,          {.v = termcmd} },
	{ ClkClientWin,         MODKEY,     Button1, movemouse,      {0} },
	{ ClkClientWin,         MODKEY,     Button2, togglefloating, {0} },
	{ ClkClientWin,         MODKEY,     Button3, resizemouse,    {0} },
	{ ClkTagBar,            0,          Button1, view,           {0} },
	{ ClkTagBar,            0,          Button3, toggleview,     {0} },
	{ ClkTagBar,            MODKEY,     Button1, tag,            {0} },
	{ ClkTagBar,            MODKEY,     Button3, toggletag,      {0} },
};
