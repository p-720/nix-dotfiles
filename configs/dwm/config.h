#include <X11/XF86keysym.h>
#include <limits.h>
#include <time.h>
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
#define SPECIAL_FIRST 12
#define SPECIAL_GAP 50
#define SPECIALTAGS  ((((1u << LENGTH(tags)) - 1) ^ ((1u << SPECIAL_FIRST) - 1)))
/* how long a spawned overlay may take to produce its window */
#define SPECIAL_SPAWN_GRACE 20
/* taffybar only ever gets the numbered workspaces: an overlay is reached by keys, and
   advertising 21 desktops is what made the bar report overlay windows on workspace 1 */
static const char *ewmhTags[] = {
	"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12",
};
/* One in-flight spawn per overlay tag. Keyed by tag rather than by what is on screen,
   so hiding the overlay or switching workspace while the app starts still lands the
   window on its overlay, and a press while a spawn is in flight never forks a second copy. */
typedef struct {
	int tag;                 /* SPECIAL_FIRST..LENGTH(tags)-1, 0 = slot free */
	const char *cls;         /* res_class we expect the spawned app to report */
	Window guess;            /* window already claimed for this spawn, 0 = none yet */
	unsigned int guess_tags; /* what to give that window back if the mark disagrees */
	int monnum;              /* monitor the press came from, so the window lands there */
	time_t deadline;
} SpecialSpawn;
static SpecialSpawn pendingspecial[LENGTH(tags) - SPECIAL_FIRST];
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
	int n = 0, i, x, w, yy, rh, fw, tw;

	for (c = m->clients; c; c = c->next) {
		/* the overlays are floating and sized by centerspecial(); counting one as a tiled
		   client reserved a column for a window this layout never places */
		if (!ISVISIBLE(c) || c->isfloating)
			continue;
		if (!ff && strstr(c->clas, "irefox"))
			ff = c;
		else if (!tg && strstr(c->clas, "elegram"))
			tg = c;
		else if (n < 64)
			others[n++] = c;
	}

	if (!ff && !tg) {
		tile(m);
		return;
	}

	/* each column keeps its border allowance and hands it back with -2*bw, the way tile()
	   does; passing m->wh straight through made the pair taller than the work area.
	   interact 0 for the same reason as tile(): the flag only picks which bounds the
	   request is clamped to, and dwm skips size hints for tiled clients anyway. */
	fw = ff ? (int)(m->ww * 0.20) : 0;
	if (ff) {
		resize(ff, m->wx, m->wy, fw - 2 * ff->bw, m->wh - 2 * ff->bw, 0);
	}

	x = m->wx + fw;
	w = m->ww - fw;
	if (tg) {
		if (n > 0) {
			tw = (int)(w * 0.618);
			resize(tg, x, m->wy, tw - 2 * tg->bw, m->wh - 2 * tg->bw, 0);
			x += tw;
			w -= tw;
		} else {
			resize(tg, x, m->wy, w - 2 * tg->bw, m->wh - 2 * tg->bw, 0);
			w = 0;
		}
	}

	yy = m->wy;
	for (i = 0; i < n && w > 0; i++) {
		rh = (m->wy + m->wh - yy) / (n - i);
		resize(others[i], x, yy, w - 2 * others[i]->bw, rh - 2 * others[i]->bw, 0);
		yy += rh;
	}
	/* deliberately no restack(): dwm 6.6 arrange() restacks after the layout returns, and
	   a second one here redrew the bar and re-stacked the whole monitor on every arrange */
}

/* layout(s) */
static const float mfact     = 0.70; /* factor of master area size [0.05..0.95] */
static const int nmaster     = 1;    /* number of clients in master area */
static const int resizehints = 0;    /* fill the tile even when clients advertise aspect-ratio hints */
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

/* a monitor is never left showing nothing; fall back to the first workspace it owns */
static unsigned int
hometag(Monitor *m)
{
	int i;

	for (i = 0; i < SPECIAL_FIRST; i++)
		if (tagowner[i] == m->num)
			return 1u << i;
	return 1u;
}

/* ff-tg is class-based, so it may only ever be the layout of a monitor that is showing
   workspace 11; on leaving, back to tile. */
static void
telegramlayout(Monitor *m, unsigned int viewtags)
{
	if (!m)
		return;
	if (viewtags & (1u << 10))
		m->lt[m->sellt] = &layouts[3];
	else if (m->lt[m->sellt] == &layouts[3])
		m->lt[m->sellt] = &layouts[0];
}

/* dwm keeps a tagset per monitor, so the same tag can be displayed by both.
   sendmon then retags a moved window to the other monitor's view; when that
   monitor later switches away, the window is tagged for a workspace nobody
   displays and dwm 6.6 parks it off-screen instead of unmapping it. Take the
   tag for one monitor and drag its windows along. */
static void
claimtag(Monitor *m, unsigned int mask)
{
	Monitor *mm;
	Client *c, *next;
	int i;

	if (!m || !mask)
		return;
	for (mm = mons; mm; mm = mm->next) {
		if (mm == m)
			continue;
		mm->tagset[mm->seltags] &= ~mask;
		if (!mm->tagset[mm->seltags])
			mm->tagset[mm->seltags] = hometag(mm);
	}
	m->tagset[m->seltags] |= mask;
	for (mm = mons; mm; mm = mm->next) {
		if (mm == m)
			continue;
		for (c = mm->clients; c; c = next) {
			next = c->next;
			if (!(c->tags & mask))
				continue;
			sendmon(c, m);
			/* sendmon widens the tags to the whole destination view */
			c->tags = mask;
		}
	}
	/* a monitor that just lost this tag arranges whatever is left of its own view, so its
	   layout follows that view. The monitor about to *display* mask is synced by viewtag
	   with the whole view view() installs, which claimtag cannot see yet. */
	for (mm = mons; mm; mm = mm->next)
		telegramlayout(mm, mm->tagset[mm->seltags]);
	for (i = 0; i < LENGTH(tags); i++)
		if (mask & (1u << i))
			tagowner[i] = m->num;
}

/* dwm starts every monitor on workspace 1; that shared tag is where cross
   monitor moves strand windows */
static void
initmonitors(void)
{
	Monitor *m;

	for (m = mons; m; m = m->next)
		m->tagset[0] = m->tagset[1] = hometag(m);
}

/* hyprland ALT+SUPER+1/0/2/9/minus: move workspace to monitor */
static void
movetag(const Arg *arg)
{
	Monitor *m = monitorbyindex(arg->i);
	unsigned int tag;
	int idx = -1, i;

	if (!m || m == selmon)
		return;
	/* only the numbered workspace travels; overlays stay on the monitor that opened them */
	tag = selmon->tagset[selmon->seltags] & ((1u << SPECIAL_FIRST) - 1);
	for (i = 0; i < SPECIAL_FIRST; i++)
		if (tag & (1u << i)) {
			idx = i;
			break;
		}
	if (idx < 0)
		return;

	claimtag(m, tag);
	selmon = m;
	/* property before arrange: picom only classifies a state change as a workspace
	   switch when _NET_CURRENT_DESKTOP already moved (pijulius/picom cee741a4). Buys
	   nothing until dwm stops sliding hidden clients instead of unmapping them. */
	updatecurrentdesktop();
	focus(NULL);
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

/* hyprland special apps; tags 13-21 are hidden scratch tags.
   Every spawn goes through dwm-overlay(1), which finds the exact window the app creates
   and marks it _DWM_SPECIAL_TAG; -F asks firefox to drop its chrome the way
   firefox-pwa did (dwm ignores _NET_WM_STATE property writes, so geometry stays ours). */
static const char *special_alacritty[] =   { "dwm-overlay", "12", "Alacritty", "--", "alacritty", NULL };
static const char *special_openai[] =      { "dwm-overlay", "13", "firefox", "-F", "--", "firefox", "--new-window", "https://chatgpt.com/", NULL };
static const char *special_deepseek[] =    { "dwm-overlay", "14", "firefox", "-F", "--", "firefox", "--new-window", "https://chat.deepseek.com/", NULL };
static const char *special_grok[] =        { "dwm-overlay", "15", "firefox", "-F", "--", "firefox", "--new-window", "https://grok.com/", NULL };
static const char *special_otherai[] =     { "dwm-overlay", "16", "firefox", "-F", "--", "firefox", "--new-window", "https://claude.ai/", NULL };
static const char *special_gemini[] =      { "dwm-overlay", "17", "firefox", "-F", "--", "firefox", "--new-window", "https://gemini.google.com", NULL };
static const char *special_music[] =       { "dwm-overlay", "18", "firefox", "-F", "--", "firefox", "--new-window", "https://open.spotify.com/", NULL };
static const char *special_speedcrunch[] = { "dwm-overlay", "19", "SpeedCrunch", "--", "speedcrunch", NULL };
static const char *special_emacs[] =       { "dwm-overlay", "20", "Emacs", "--", "emacs", NULL };
static const char **specialcmds[] = {
	special_alacritty, special_openai, special_deepseek, special_grok,
	special_otherai, special_gemini, special_music, special_speedcrunch,
	special_emacs
};
/* the res_class each spawn is expected to report, indexed like specialcmds */
static const char *specialcls[] = {
	"Alacritty", "firefox", "firefox", "firefox", "firefox",
	"firefox", "firefox", "SpeedCrunch", "Emacs"
};
/* single-purpose apps may be re-shown from a window that is still running but hidden.
   For the firefox overlays reuse is by overlay tag only - your own browsing windows are
   never candidates for becoming an overlay. */
static const int specialreuse[] = { 1, 0, 0, 0, 0, 0, 0, 1, 1 };
static const char *telegram_ffcmd[] = { "env", "DWM_NO_SPECIAL_TAG=1", "firefox-pwa", "https://ug.kyrgyzstan.kg/pomotask/", NULL };
static const char *telegram_tgcmd[] = {
	"sh", "-c", "env GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb WEBKIT_DISABLE_DMABUF_RENDERER=1 Telegram", NULL
};

/* one walk answers both halves of the workspace 11 pair; asking twice meant a second
   pass over every client tagged for it */
static void
pairpresent(Monitor *m, unsigned int mask, int *ff, int *tg)
{
	Client *c;

	*ff = *tg = 0;
	for (c = m->clients; c; c = c->next) {
		if (!(c->tags & mask))
			continue;
		if (!*ff && strstr(c->clas, "irefox"))
			*ff = 1;
		else if (!*tg && strstr(c->clas, "elegram"))
			*tg = 1;
	}
}

static void
viewtag(const Arg *arg)
{
	Monitor *m = tagmonitor(arg->ui), *prev = selmon;
	int earlyreturn, hasff, hastg;

	if (m != selmon) {
		unfocus(selmon->sel, 0);
		selmon = m;
		focus(NULL);
	}

	claimtag(m, arg->ui & ((1u << SPECIAL_FIRST) - 1));
	/* the view view() installs replaces the whole tagset, so claimtag's sync - which still
	   saw workspace 11 in it - cannot decide this monitor's layout */
	telegramlayout(m, arg->ui & TAGMASK);
	/* view() arranges only when the tagset changes, so this is recorded before it: when
	   view() early-returns, this arrange is what applies the layout claimtag chose */
	earlyreturn = (m->tagset[m->seltags] == (arg->ui & TAGMASK));
	view(arg);
	if (!selmon)
		return;
	if (earlyreturn)
		arrange(selmon);
	/* workspace 11: hyprland launches the missing Telegram/Firefox pair */
	if (arg->ui & (1 << 10)) {
		pairpresent(selmon, 1 << 10, &hasff, &hastg);
		if (!hasff)
			spawn(&(Arg){ .v = telegram_ffcmd });
		if (!hastg)
			spawn(&(Arg){ .v = telegram_tgcmd });
	}
	/* follow only when the workspace moved to another monitor */
	if (selmon != prev)
		warppointer(selmon->sel);
}

static void
centerspecial(Client *c, Monitor *m)
{
	int ow, oh;

	if (!c || !m)
		return;
	ow = m->mw - 2 * SPECIAL_GAP;
	oh = m->mh - 2 * SPECIAL_GAP;
	c->isfloating = 1;
	c->bw = 0;
	c->x = m->mx + SPECIAL_GAP;
	c->y = m->my + SPECIAL_GAP;
	c->w = 0;
	c->h = 0;
	resize(c, c->x, c->y, ow, oh, 0);
	XRaiseWindow(dpy, c->win);
}

static SpecialSpawn *
pendinglookup(int tag)
{
	int i;

	for (i = 0; i < (int)LENGTH(pendingspecial); i++)
		if (pendingspecial[i].tag == tag && time(NULL) < pendingspecial[i].deadline)
			return &pendingspecial[i];
	return NULL;
}

static void
pendingstart(int tag, const char *cls, Monitor *m)
{
	int i;

	for (i = 0; i < (int)LENGTH(pendingspecial); i++)
		if (!pendingspecial[i].tag || time(NULL) >= pendingspecial[i].deadline)
			break;
	pendingspecial[i].tag = tag;
	pendingspecial[i].cls = cls;
	pendingspecial[i].guess = 0;
	pendingspecial[i].guess_tags = 0;
	pendingspecial[i].monnum = m ? m->num : -1;
	pendingspecial[i].deadline = time(NULL) + SPECIAL_SPAWN_GRACE;
}

static void
pendingclear(SpecialSpawn *p)
{
	p->tag = 0;
	p->cls = NULL;
	p->guess = 0;
	p->guess_tags = 0;
	p->monnum = -1;
	p->deadline = 0;
}

static int
clientclassis(Client *c, const char *cls)
{
	return !strcmp(c->clas, cls);
}

/* the window tagged for this overlay. onscreen = 1 only matches one you can actually
   see, which is what decides press-against-press: an armed tag with no window is not
   an open overlay. */
static Client *
overlayclient(unsigned int mask, Monitor **mon, int onscreen)
{
	Monitor *m;
	Client *c;

	for (m = mons; m; m = m->next) {
		for (c = m->clients; c; c = c->next) {
			if (!(c->tags & mask))
				continue;
			if (onscreen && !(c->tags & m->tagset[m->seltags]))
				continue;
			if (mon)
				*mon = m;
			return c;
		}
	}
	return NULL;
}

static Monitor *
taggedmonitor(unsigned int mask)
{
	Monitor *m;

	for (m = mons; m; m = m->next)
		if (m->tagset[m->seltags] & mask)
			return m;
	return NULL;
}

/* reuse candidates for the single-purpose overlays: running but on nobody's screen.
   Never grabs a window you are looking at, never grabs another overlay. */
static Client *
strandedclient(const char *cls)
{
	Monitor *m;
	Client *c;

	for (m = mons; m; m = m->next)
		for (c = m->clients; c; c = c->next) {
			if (c->tags & SPECIALTAGS)
				continue;
			if (c->tags & m->tagset[m->seltags])
				continue;
			if (clientclassis(c, cls))
				return c;
		}
	return NULL;
}

/* called from manage() before the client is attached: only a window belonging to a
   spawn we started may join an overlay. Everything else loses the overlay tags it
   inherited from the monitor view, so opening your own firefox while an overlay tag is
   showing cannot turn it into an overlay. */
static void
overlayclaim(Client *c, XWindowAttributes *wa)
{
	SpecialSpawn *p;
	Monitor *m;
	int i;

	p = NULL;
	if (wa->width > 100 && wa->height > 100) {
		for (i = 0; i < (int)LENGTH(pendingspecial); i++) {
			if (!pendingspecial[i].tag || pendingspecial[i].guess
			 || time(NULL) >= pendingspecial[i].deadline)
				continue;
			if (!clientclassis(c, pendingspecial[i].cls))
				continue;
			p = &pendingspecial[i];
			break;
		}
	}
	if (!p) {
		c->tags &= ~SPECIALTAGS;
		return;
	}
	p->guess = c->win;
	p->guess_tags = c->mon->tagset[c->mon->seltags] & ~SPECIALTAGS;
	/* land on the monitor the press came from, not whichever one happens to be focused
	   when the app finally maps its window */
	m = monitorbyindex(p->monnum);
	c->mon = m ? m : selmon;
	c->tags = 1u << p->tag;
	c->isfloating = 1;
}

/* the wrapper marks the exact window it started. Honoured whenever that marker
   arrives - after a toggle-off, a workspace switch, or a slow app - and it overrules
   the class guess in overlayclaim, handing the wrongly claimed window back its
   workspace. Geometry stays with configure()/centerspecial(): resizing here is what
   made firefox fight dwm for the window size. */
static void
overlaymark(Client *c)
{
	SpecialSpawn *p;
	Atom real, atom = XInternAtom(dpy, "_DWM_SPECIAL_TAG", False);
	unsigned char *data = NULL;
	unsigned long n, extra;
	Client *wrong;
	int format, val;

	if (XGetWindowProperty(dpy, c->win, atom, 0, 1, False, XA_CARDINAL, &real,
		&format, &n, &extra, &data) != Success || !n) {
		XFree(data);
		return;
	}
	val = (int)*(long *)data;
	XFree(data);
	if (real != XA_CARDINAL || format != 32 || val < SPECIAL_FIRST || val >= LENGTH(tags))
		return;

	p = pendinglookup(val);
	if (p && p->guess && p->guess != c->win && (wrong = wintoclient(p->guess))) {
		wrong->tags = p->guess_tags ? p->guess_tags
			: (wrong->mon->tagset[wrong->mon->seltags] & ~SPECIALTAGS);
		if (!wrong->tags)
			wrong->tags = 1u << (SPECIAL_FIRST - 1);
		wrong->isfloating = 0;
		arrange(wrong->mon);
	}
	if (p)
		pendingclear(p);

	c->tags = 1u << val;
	c->isfloating = 1;
	centerspecial(c, c->mon);
	arrange(c->mon);
	updateclientlist();
}

/* an overlay tag with no window left on this monitor is dead state: drop it so the
   next press is a clean open instead of a hide that hides nothing. */
static void
overlaycleanup(Monitor *m)
{
	int idx;

	if (!m)
		return;
	for (idx = SPECIAL_FIRST; idx < LENGTH(tags); idx++) {
		if (!(m->tagset[m->seltags] & (1u << idx)))
			continue;
		if (overlayclient(1u << idx, NULL, 0))
			continue;
		m->tagset[m->seltags] &= ~(1u << idx);
	}
	if (!m->tagset[m->seltags])
		m->tagset[m->seltags] = hometag(m);
}

static void
togglespecial(const Arg *arg)
{
	Monitor *m, *mm, *own = NULL;
	Client *c, *shown;
	unsigned int mask;
	int idx = arg->i, pos;

	if (!selmon || idx < SPECIAL_FIRST || idx >= LENGTH(tags))
		return;
	mask = 1u << idx;
	pos = idx - SPECIAL_FIRST;

	/* shown anywhere -> hide it there. A press must always be able to close the
	   overlay; bringing it to you only applies when nothing is showing. */
	if ((c = overlayclient(mask, &own, 1))) {
		/* strip any workspace tag the overlay picked up (a sendmon from movedir, a
		   tagto, ...) or hiding the overlay tag leaves the window on screen */
		for (c = own->clients; c; c = c->next)
			if (c->tags & mask)
				c->tags = mask;
		own->tagset[own->seltags] &= ~mask;
		if (!own->tagset[own->seltags])
			own->tagset[own->seltags] = hometag(own);
		if (own != selmon) {
			unfocus(selmon->sel, 0);
			selmon = own;
		}
		updatecurrentdesktop();
		arrange(own);
		focus(NULL);
		updateclientlist();
		return;
	}

	/* armed on this monitor but the app has not arrived yet: a press means "not now",
	   and the spawn stays alive so the window still lands on this overlay, parked.
	   When the arm is on the other monitor this falls through and re-arms here. */
	if (!overlayclient(mask, &own, 0) && pendinglookup(idx)
	 && (m = taggedmonitor(mask)) == selmon) {
		m->tagset[m->seltags] &= ~mask;
		if (!m->tagset[m->seltags])
			m->tagset[m->seltags] = hometag(m);
		updatecurrentdesktop();
		arrange(m);
		updateclientlist();
		return;
	}

	/* show it here: reuse the window already tagged for this overlay wherever it
	   lives (it moves to this monitor), or a still-running window of that app's class
	   when nothing is tagged */
	shown = overlayclient(mask, NULL, 0);
	if (!shown && specialreuse[pos])
		shown = strandedclient(specialcls[pos]);
	m = selmon;

	/* drop the overlay from any other monitor before putting it on this one */
	for (mm = mons; mm; mm = mm->next) {
		if (mm == m || !(mm->tagset[mm->seltags] & mask))
			continue;
		mm->tagset[mm->seltags] &= ~mask;
		if (!mm->tagset[mm->seltags])
			mm->tagset[mm->seltags] = hometag(mm);
		arrange(mm);
	}
	/* one overlay per monitor */
	tagowner[idx] = m->num;
	m->tagset[m->seltags] &= ~SPECIALTAGS;
	m->tagset[m->seltags] |= mask;
	if (shown && shown->mon != m)
		sendmon(shown, m);
	/* sendmon assigns the target monitor's whole tagset, which would leave the overlay
	   tagged to the numbered workspace too - then hiding the overlay tag leaves the
	   window on screen looking like a normal window */
	if (shown)
		shown->tags = mask;

	updatecurrentdesktop();
	arrange(m);
	if (shown) {
		centerspecial(shown, m);
		focus(shown);
	} else {
		focus(NULL);
		if (!pendinglookup(idx)) {
			pendingstart(idx, specialcls[pos], m);
			spawn(&(Arg){ .v = specialcmds[pos] });
		}
	}
	updateclientlist();
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

/* ctrl+super+N: dwm core toggleview lets two monitors show the same workspace,
   which is how windows get stranded, so adding N hands the workspace to this
   monitor and removing it just drops it from this view */
static void
toggleviewtag(const Arg *arg)
{
	unsigned int mask = arg->ui & ((1u << SPECIAL_FIRST) - 1);

	if (!mask)
		return;
	if (selmon->tagset[selmon->seltags] & mask) {
		selmon->tagset[selmon->seltags] &= ~mask;
		if (!selmon->tagset[selmon->seltags])
			selmon->tagset[selmon->seltags] = hometag(selmon);
	} else {
		claimtag(selmon, mask);
	}
	telegramlayout(selmon, selmon->tagset[selmon->seltags]);
	updatecurrentdesktop();
	focus(NULL);
	arrange(selmon);
	updateclientlist();
}

/* ctrl+super+shift+N: core toggletag tags a window for a workspace its own
   monitor will never display, so hand the workspace over and move the window to it */
static void
tagclientto(const Arg *arg)
{
	Client *c = selmon->sel;
	Monitor *m;
	unsigned int mask = arg->ui & ((1u << SPECIAL_FIRST) - 1);

	if (!c || !mask)
		return;
	if (c->tags & mask) {
		c->tags &= ~mask;
		if (!c->tags)
			c->tags = selmon->tagset[selmon->seltags];
		telegramlayout(selmon, selmon->tagset[selmon->seltags]);
		focus(NULL);
		arrange(selmon);
		updateclientlist();
		return;
	}
	m = tagmonitor(mask);
	claimtag(m, mask);
	if (c->mon != m)
		sendmon(c, m);
	c->tags = mask;
	focus(c);
	telegramlayout(m, m->tagset[m->seltags]);
	updatecurrentdesktop();
	arrange(m);
	updateclientlist();
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
		/* empty workspace: no client to step from, still cross to the adjacent monitor */
		if ((m = adjmon(dir))) {
			selmon = m;
			focus(NULL);
			updatecurrentdesktop();
			warppointer(selmon->sel);
		}
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
	{ MODKEY|ControlMask,           KEY,      toggleviewtag,  {.ui = 1 << TAG} }, \
	{ MODKEY|ShiftMask,             KEY,      tagto,          {.ui = 1 << TAG} }, \
	{ MODKEY|ControlMask|ShiftMask, KEY,      tagclientto,    {.ui = 1 << TAG} }

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
	{ MODKEY|ControlMask,           XK_equal,            toggleviewtag,  {.ui = 1 << 11} },
	{ MODKEY|ShiftMask,             XK_equal,            tagto,          {.ui = 1 << 11} },
	{ MODKEY|ControlMask|ShiftMask, XK_equal,            tagclientto,    {.ui = 1 << 11} },
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
	{ ClkTagBar,            0,          Button1, viewtag,        {0} },
	{ ClkTagBar,            0,          Button3, toggleviewtag,  {0} },
	{ ClkTagBar,            MODKEY,     Button1, tagto,          {0} },
	{ ClkTagBar,            MODKEY,     Button3, tagclientto,    {0} },
};
