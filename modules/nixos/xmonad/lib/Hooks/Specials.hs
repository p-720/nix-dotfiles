-- |

module Hooks.Specials where

import Control.Monad (unless, when)
import Data.Char (toLower)
import Data.List (isInfixOf, lookup)
import Data.Time.Clock.POSIX (getPOSIXTime)
import XMonad
import XMonad.Actions.DynamicWorkspaces (addHiddenWorkspace)
import XMonad.Core (ExtensionClass)
import XMonad.Hooks.ManageHelpers (doRectFloat)
import qualified XMonad.StackSet as W
import qualified XMonad.Util.ExtensibleState as ES
import XMonad.Util.NamedScratchpad (scratchpadWorkspaceTag)

-- hyprland's special workspaces that hold a browser window
specialSites =
  [ ("openai", "https://chatgpt.com/"),
    ("deepseek", "https://chat.deepseek.com/"),
    ("grok", "https://grok.com/"),
    ("otherai", "https://claude.ai/"),
    ("gemini", "https://aistudio.google.com/prompts/new_chat"),
    ("music", "https://open.spotify.com/")
  ]

-- hyprland specials covered the workspace with gaps; floats ignore struts,
-- so keep a slice clear for the bottom bar
specialRect = W.RationalRect 0.04 0.07 0.92 0.86

-- window adopted for each special
data SpecialWindows = SpecialWindows [(String, Window)] deriving (Read, Show)

instance ExtensionClass SpecialWindows where
  initialValue = SpecialWindows []

-- specials with a spawn still in flight
data PendingSpecials = PendingSpecials [(String, Integer)] deriving (Read, Show)

instance ExtensionClass PendingSpecials where
  initialValue = PendingSpecials []

spawnWindow :: Integer
spawnWindow = 10

now :: X Integer
now = liftIO $ round . realToFrac <$> getPOSIXTime

-- firefox cannot pin WM_CLASS and its title is still "Mozilla Firefox" when
-- it maps, so the first firefox window to be managed right after the key
-- press is the one being claimed
claimSpecial :: ManageHook
claimSpecial = do
  w <- ask
  isFirefox <- fmap (isInfixOf "firefox" . map toLower) className
  claimed <- liftX $ do
    t <- now
    PendingSpecials ps <- ES.get
    let fresh = [(n, ts) | (n, ts) <- ps, t - ts <= spawnWindow]
    ES.put (PendingSpecials fresh)
    case (isFirefox, fresh) of
      (True, (name, _) : _) -> do
        SpecialWindows sw <- ES.get
        ES.put (PendingSpecials (filter ((/= name) . fst) fresh))
        ES.put (SpecialWindows ((name, w) : filter ((/= name) . fst) sw))
        pure True
      _ -> pure False
  if claimed then doRectFloat specialRect else mempty

-- toggle: hide when the window is on the current workspace, pull it back
-- otherwise, spawn when the special has no live window
toggleSpecial name url = do
  sw <- gets windowset
  let currentTag = W.currentTag sw
      visible = maybe [] W.integrate . W.stack . W.workspace $ W.current sw
  SpecialWindows adopted <- ES.get
  case lookup name adopted of
    Just w | w `elem` W.allWindows sw ->
      if w `elem` visible
        then hideWindow w
        else showWindow w currentTag
    _ -> do
      t <- now
      PendingSpecials ps <- ES.get
      let idle = maybe True (\ts -> t - ts > spawnWindow) (lookup name ps)
      when idle $ do
        ES.put $ SpecialWindows (filter ((/= name) . fst) adopted)
        ES.put $ PendingSpecials ((name, t) : filter ((/= name) . fst) ps)
        spawn $ "firefox --new-window " ++ url
  where
    hideWindow w = do
      tags <- gets (map W.tag . W.workspaces . windowset)
      unless (scratchpadWorkspaceTag `elem` tags) $ addHiddenWorkspace scratchpadWorkspaceTag
      windows $ W.shiftWin scratchpadWorkspaceTag w
    showWindow w tag =
      windows $ \s -> W.focusWindow w $ W.float w specialRect $ W.shiftWin tag w s
