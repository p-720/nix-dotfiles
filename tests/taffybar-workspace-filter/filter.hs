-- Transcribes the Hyprland bits of modules/nixos/taffybar/taffybar.hs (the
-- FromJSON rows, the geometry matcher, the per-bar workspace filter) so they can
-- be run against real `hyprctl -j` output from Hyprland 0.56.2. Kept as a copy
-- on purpose: the real thing lives in a Main module with a GTK main loop.
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:), (.:?))
import qualified Data.ByteString.Lazy as BL
import Data.List (find, isPrefixOf, sort)
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import System.Environment (getArgs)

data HyprMonitor = HyprMonitor
  { hmName :: T.Text,
    hmX :: Int,
    hmY :: Int,
    hmW :: Int,
    hmH :: Int
  }
  deriving (Show)

instance FromJSON HyprMonitor where
  parseJSON = withObject "HyprMonitor" $ \o ->
    HyprMonitor
      <$> o .: "name"
      <*> o .: "x"
      <*> o .: "y"
      <*> o .: "width"
      <*> o .: "height"

data HyprWorkspaceRow = HyprWorkspaceRow
  { hwName :: T.Text,
    hwMonitor :: T.Text
  }
  deriving (Show)

instance FromJSON HyprWorkspaceRow where
  parseJSON = withObject "HyprWorkspaceRow" $ \o -> do
    name <- o .: "name"
    monitor <- o .:? "monitor"
    pure HyprWorkspaceRow {hwName = name, hwMonitor = fromMaybe "" monitor}

type Box = (Int, Int, Int, Int)

boxesOf :: [HyprMonitor] -> [(Int, Int, Int, Int, T.Text)]
boxesOf ms = [(hmX m, hmY m, hmW m, hmH m, hmName m) | m <- ms]

matchMonitorBox :: [(Int, Int, Int, Int, T.Text)] -> Box -> Maybe (Int, Int, Int, Int, T.Text)
matchMonitorBox bxes (x, y, w, h) =
  case [b | b <- bxes, matchesPosition b] of
    (b:_) -> Just b
    [] -> listToMaybe [b | b <- bxes, matchesSize b]
  where
    matchesPosition (bx, by, _, _, _) = bx == x && by == y
    matchesSize (_, _, bw, bh, _) = bw == w && bh == h

rowsToMap :: [HyprWorkspaceRow] -> M.Map T.Text T.Text
rowsToMap = foldr (\row acc -> M.insert (hwName row) (hwMonitor row) acc) M.empty

-- The workspace record as the filter sees it.
data Ws = Ws {wsName :: T.Text, wsNum :: Maybe Int, wsSpecial :: Bool}

-- own monitor, is-primary, more-than-one-monitor, workspace table
scopedM :: Maybe T.Text -> Bool -> Bool -> M.Map T.Text T.Text -> Ws -> Bool
scopedM own isPrimary multiMonitor table ws
  | wsSpecial ws = False
  | Just monitor <- own, Just wm <- M.lookup (wsName ws) table, not (T.null wm) = wm == monitor
  | otherwise = maybe False underLimit (wsNum ws)
  where
    underLimit n
      | isPrimary && multiMonitor = n < 6
      | isPrimary = n < 12
      | otherwise = n >= 6 && n < 12

-- everything but the single-screen case
scoped :: Maybe T.Text -> Bool -> M.Map T.Text T.Text -> Ws -> Bool
scoped own isPrimary = scopedM own isPrimary True

-- Transcribed from taffybar.hs. Hyprland sends the wheel as a *smooth* scroll
-- event, whose direction field comes back ScrollDirectionSmooth, so the delta
-- sign is the only usable signal there. Matching discrete Up/Down alone is the
-- "scrolling the bar does nothing under Hyprland" bug. Just True = wheel up.
smoothStep :: Double -> Double -> Maybe Bool
smoothStep dx dy
  | abs dy < abs dx = Nothing
  | dy < 0 = Just True
  | dy > 0 = Just False
  | otherwise = Nothing

-- Transcribed from taffybar.hs. Hyprland 0.56.2 parses `dispatch <rest>` as Lua
-- when the config is Lua (the documented `dispatch workspace m+1` then gets
-- `')' expected near 'm'`, hyprctl included), and as plain args when it is
-- hyprlang. Both spellings are sent, whichever answers ok wins.
workspaceSwitchForms :: Bool -> [[String]]
workspaceSwitchForms previous = [["dispatch", luaCall], ["dispatch", "workspace", step]]
  where
    step = if previous then "m-1" else "m+1"
    luaCall = "hl.dsp.focus({workspace=\"" ++ step ++ "\"})"

expect :: String -> Bool -> IO ()
expect name ok = putStrLn (pad name ++ (if ok then " PASS" else " FAIL")) >> unless ok (pure ())
  where
    pad s = s ++ replicate (max 1 (44 - length s)) '.'

main :: IO ()
main = do
  args <- getArgs
  monRaw <- BL.readFile (args !! 0)
  wsRaw <- BL.readFile (args !! 1)
  let monitors = either error id (eitherDecode monRaw) :: [HyprMonitor]
      rows = either error id (eitherDecode wsRaw) :: [HyprWorkspaceRow]
      table = rowsToMap rows
      bxes = boxesOf monitors
      named n = [w | w <- rows, hwName w == n]
      wsFor w = Ws (hwName w) (readMaybeInt (T.unpack (hwName w))) (T.isPrefixOf "special:" (hwName w) || maybe False (< 0) (readMaybeInt (T.unpack (hwName w))))
      visibleOn mon primary = [hwName w | w <- rows, scoped (Just mon) primary table (wsFor w)]
  putStrLn $ "monitors: " ++ show monitors
  putStrLn $ "workspace->monitor: " ++ show (M.toAscList table)

  expect "01 parse monitors count" (length monitors == 2)
  expect "02 parse workspaces count" (length rows >= 12)
  expect "03 DP-5 at layout x=0" (hmX (head (filter (\m -> hmName m == "DP-5") monitors)) == 0)
  expect "04 HDMI-A-3 at layout x=2560" (hmX (head (filter (\m -> hmName m == "HDMI-A-3") monitors)) == 2560)

  -- geometry matching, in both GDK orders
  expect "05 match primary by position" (fmap (\(_, _, _, _, n) -> n) (matchMonitorBox bxes (0, 0, 2560, 1080)) == Just "DP-5")
  expect "06 match secondary by position" (fmap (\(_, _, _, _, n) -> n) (matchMonitorBox bxes (2560, 0, 1920, 1080)) == Just "HDMI-A-3")
  expect "07 hotplug reorder keeps match" (fmap (\(_, _, _, _, n) -> n) (matchMonitorBox (reverse bxes) (2560, 0, 1920, 1080)) == Just "HDMI-A-3")
  -- scaled monitor: GTK origin differs from layout origin, size still identifies it
  let scaled = [(2048, 0, 1920, 1080, "HDMI-A-3"), (0, 0, 2560, 1080, "DP-5")]
  expect "08 size fallback when x/y unknown" (fmap (\(_, _, _, _, n) -> n) (matchMonitorBox scaled (3000, 7, 1920, 1080)) == Just "HDMI-A-3")
  expect "09 no bogus match" (matchMonitorBox bxes (1000, 1000, 800, 600) == Nothing)

  -- per-bar filtering on the real user layout
  let primaryShown = visibleOn "DP-5" True
      secondaryShown = visibleOn "HDMI-A-3" False
  putStrLn $ "  DP-5/primary   -> " ++ show primaryShown
  putStrLn $ "  HDMI-A-3/sec   -> " ++ show secondaryShown
  expect "10 primary shows 1-6" (sort primaryShown == ["1", "2", "3", "4", "5", "6"])
  expect "11 secondary shows 7-12" (sort secondaryShown == ["10", "11", "12", "7", "8", "9"])
  expect "12 specials never shown" (not (any (T.isPrefixOf "special:") (primaryShown ++ secondaryShown)))
  expect "13 no overlap between bars" (null (intersect primaryShown secondaryShown))

  -- live-move: workspace 3 dragged to the other output
  let table' = M.insert "3" "HDMI-A-3" table
      primaryShown' = [hwName w | w <- rows, scoped (Just "DP-5") True table' (wsFor w)]
      secondaryShown' = [hwName w | w <- rows, scoped (Just "HDMI-A-3") False table' (wsFor w)]
  expect "14 move leaves primary" (notElem "3" primaryShown')
  expect "15 move arrives on secondary" (elem "3" secondaryShown')

  -- fallbacks: no monitor resolved for this bar at all, and no table yet
  let noMonitor = [hwName w | w <- rows, scoped (Nothing :: Maybe T.Text) True table (wsFor w)]
  putStrLn $ "  no monitor      -> " ++ show noMonitor
  expect "16 unresolved bar monitor -> numeric" (sort noMonitor == ["1", "2", "3", "4", "5"])
  let emptyTable = [hwName w | w <- rows, scoped (Just "DP-5") True M.empty (wsFor w)]
  putStrLn $ "  empty table     -> " ++ show emptyTable
  expect "17 empty table -> numeric" (sort emptyTable == ["1", "2", "3", "4", "5"])
  -- one screen: the single bar carries every workspace it is told about
  let solo = [hwName w | w <- rows, scopedM (Nothing :: Maybe T.Text) True False M.empty (wsFor w)]
  putStrLn $ "  solo primary    -> " ++ show solo
  expect "22 single-monitor primary fallback = 1-11" (sort solo == ["1", "10", "11", "2", "3", "4", "5", "6", "7", "8", "9"])
  expect "23 single-monitor keeps the table path" (sort [hwName w | w <- rows, scopedM (Just "DP-5") True False table (wsFor w)] == ["1", "2", "3", "4", "5", "6"])
  let nullMonitor = [hwName w | w <- rows, scoped (Just "DP-5") True (M.insert "4" "" table) (wsFor w)]
  expect "18 null-monitor row -> numeric" (elem "4" nullMonitor)

  -- named/non-numeric workspaces
  expect "19 non-numeric hidden on primary" (visibleOn "DP-5" True /= [] && not (elem "special:alacritty" (visibleOn "DP-5" True)))
  expect "20 named workspace on known monitor follows monitor" (case named "special:alacritty" of (w:_) -> not (elem (hwName w) (visibleOn "DP-5" True)); _ -> False)
  expect "21 find import used" (isJustFind)

  -- the wheel under Hyprland: smooth events, so deltas carry the step
  putStrLn $ "  smooth dy=+1/-1  -> " ++ show (smoothStep 0 1, smoothStep 0 (-1))
  expect "24 smooth wheel down -> next" (smoothStep 0 1 == Just False)
  expect "25 smooth wheel up -> previous" (smoothStep 0 (-1) == Just True)
  expect "26 smooth half step keeps sign" (smoothStep 0 0.5 == Just False)
  expect "27 smooth no movement -> nothing" (smoothStep 0 0 == Nothing)
  expect "28 sideways swipe is not a step" (smoothStep 2 0.5 == Nothing)
  expect "29 diagonal keeps the vertical sign" (smoothStep 0.5 1 == Just False)

  -- the bytes that go over the command socket, in the order they are tried
  putStrLn $ "  scroll payload -> " ++ show (workspaceSwitchForms False)
  expect "30 first form is the Lua dispatcher" (head (workspaceSwitchForms False) == ["dispatch", "hl.dsp.focus({workspace=\"m+1\"})"])
  expect "31 legacy form kept as fallback" (workspaceSwitchForms False !! 1 == ["dispatch", "workspace", "m+1"])
  expect "32 up steps m-1 in both forms" (workspaceSwitchForms True == [["dispatch", "hl.dsp.focus({workspace=\"m-1\"})"], ["dispatch", "workspace", "m-1"]])
  where
    intersect a b = [x | x <- a, elem x b]
    readMaybeInt s = case mapM (\c -> if c >= '0' && c <= '9' then Just c else Nothing) s of
      Just ds -> Just (read s :: Int)
      Nothing -> Nothing
    isJustFind = isJust' (find (const True) [1 :: Int])
    isJust' (Just _) = True
    isJust' Nothing = False
