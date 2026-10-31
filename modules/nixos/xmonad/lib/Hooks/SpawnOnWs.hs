-- |

module Hooks.SpawnOnWs where

import Control.Monad (when)
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Time.Clock.POSIX (getPOSIXTime)
import XMonad
import XMonad.Core (ExtensionClass)
import qualified XMonad.Util.ExtensibleState as ES
import qualified XMonad.StackSet as W

-- a spawn takes seconds to map its window and logHook re-fires meanwhile
data RecentSpawns = RecentSpawns [(String, Integer)] deriving (Read, Show)

instance ExtensionClass RecentSpawns where
  initialValue = RecentSpawns []

-- hyprland's lua opened these when their workspace became visible
wsAutoSpawn :: X ()
wsAutoSpawn = do
  ws <- gets windowset
  let tag = W.currentTag ws
      here = maybe [] W.integrate . W.stack . W.workspace $ W.current ws
  when (tag `elem` ["1_11", "1_12"]) $ do
    classes <- mapM (runQuery className) here
    let has cls = any (isInfixOf cls . map toLower) classes
        missing
          | tag == "1_11" =
              [ ("telegram", not (has "telegram"), "Telegram"),
                ("ws11-firefox", not (has "firefox"), "firefox --new-window https://ug.kyrgyzstan.kg/pomotask/")
              ]
          | otherwise =
              [("ws12-firefox", not (has "firefox"), "firefox --new-window https://web.max.ru/")]
    mapM_ spawnCooled [(key, cmd) | (key, gone, cmd) <- missing, gone]
  where
    spawnCooled (key, cmd) = do
      now <- liftIO $ round . realToFrac <$> getPOSIXTime
      RecentSpawns recent <- ES.get
      when (maybe True (\t -> now - t > 20) (lookup key recent)) $ do
        ES.put $ RecentSpawns ((key, now) : filter ((/= key) . fst) recent)
        spawn cmd
