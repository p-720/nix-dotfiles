-- |

module DragSplit (dragSplit, splitResize) where

import Control.Monad (replicateM_, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, listToMaybe)
import XMonad
import XMonad.Layout.LayoutModifier
import XMonad.Util.XUtils (deleteWindow)
import qualified XMonad.StackSet as W

-- One Expand/Shrink step per this fraction of the screen width, matching the
-- delta of the layouts in Layouts.hs: the split follows the pointer instead
-- of jumping.
splitDelta :: Int
splitDelta = 3

-- drag the master/stack split with the pointer, one step per stepPx pixels.
-- Grab on the master column grows the master, grab on the stack grows the
-- stack, so the dragged boundary always follows the cursor.
splitResize :: Int -> Bool -> X ()
splitResize stepPx growLeft = do
  let step = fromIntegral (max 12 stepPx) :: Position
  anchor <- liftIO $ newIORef Nothing
  mouseDrag
    ( \x _ -> do
        start <- liftIO $ readIORef anchor
        case start of
          Nothing -> liftIO $ writeIORef anchor (Just x)
          Just a -> do
            let grow = if growLeft then x > a else x < a
                steps = if grow then (x - a) `div` step else (a - x) `div` step
            when (steps > 0) $ do
              replicateM_ (fromIntegral steps) $
                sendMessage (if grow then Expand else Shrink)
              let next = if grow then a + steps * step else a - steps * step
              liftIO $ writeIORef anchor (Just next)
    )
    (pure ())

-- input-only grab strip, cursor over it is the horizontal resize arrow
grabStrip :: Rectangle -> X Window
grabStrip (Rectangle x y w h) =
  withDisplay $ \d -> do
    root <- asks theRoot
    let screen = defaultScreenOfDisplay d
        visual = defaultVisualOfScreen screen
        attrmask = cWOverrideRedirect
    win <- io $ allocaSetWindowAttributes $ \attributes -> do
      set_override_redirect attributes True
      createWindow d root x y w h 0 0 inputOnly visual attrmask attributes
    io $ selectInput d win (exposureMask .|. buttonPressMask)
    cursor <- io $ createFontCursor d xC_sb_h_double_arrow
    io $ defineCursor d win cursor
    io $ freeCursor d cursor
    io $ mapWindow d win
    return win

-- grab window, which window the drag grows (left side of the boundary), and
-- whether that side is the master column
data DragSplit a = DragSplit [(Window, Bool, Maybe Window)] Int deriving (Read, Show)

dragSplit :: l a -> ModifiedLayout DragSplit l a
dragSplit = ModifiedLayout (DragSplit [] 0)

instance LayoutModifier DragSplit Window where
  redoLayout _ _ Nothing wrs = return (wrs, Nothing)
  redoLayout (DragSplit old _) _ (Just s) wrs = do
    mapM_ (maybe (return ()) deleteWindow . stripOf) old
    let wins = [(w, r) | (w, r) <- wrs, w `elem` W.integrate s]
        master = fromMaybe 0 (listToMaybe (W.integrate s))
        screenWidth = foldl max 0 [rect_x r + fromIntegral (rect_width r) | (_, r) <- wins]
        -- vertical boundaries: left window's right edge meets right window's
        -- left edge; the strip straddles the line by 3px each way
        boundaries =
          [ (lw, lw == master, Rectangle (rect_x rr - 3) top 6 height)
            | (lw, lr) <- wins,
              (rw, rr) <- wins,
              lw /= rw,
              rect_x lr + fromIntegral (rect_width lr) == rect_x rr,
              let top = max (rect_y lr) (rect_y rr),
              let bottom = min (rect_y lr + fromIntegral (rect_height lr)) (rect_y rr + fromIntegral (rect_height rr)),
              let height = fromIntegral (bottom - top),
              bottom - top > 10
          ]
    handles <- mapM makeStrip boundaries
    return (wrs, Just (DragSplit handles (fromIntegral screenWidth)))
    where
      makeStrip (leftWin, isMaster, rect) = do
        h <- grabStrip rect
        return (leftWin, isMaster, Just h)
      stripOf (_, _, h) = h

  handleMess (DragSplit st screenWidth) m
    | Just e <- fromMessage m :: Maybe Event = handleEvent st screenWidth e >> return Nothing
    | Just Hide <- fromMessage m = cleanup st >> return (Just (DragSplit [] screenWidth))
    | Just ReleaseResources <- fromMessage m = cleanup st >> return (Just (DragSplit [] screenWidth))
    where
      cleanup = mapM_ (maybe (return ()) deleteWindow . stripOf)
      stripOf (_, _, h) = h
  handleMess _ _ = return Nothing

handleEvent :: [(Window, Bool, Maybe Window)] -> Int -> Event -> X ()
handleEvent st screenWidth ButtonEvent {ev_window = ew, ev_event_type = et}
  | et == buttonPress, Just (win, isMaster) <- findStrip ew st = do
      focus win
      splitResize (screenWidth * splitDelta `div` 100) isMaster
handleEvent _ _ _ = return ()

findStrip :: Window -> [(Window, Bool, Maybe Window)] -> Maybe (Window, Bool)
findStrip _ [] = Nothing
findStrip h ((w, m, Just hw) : rest)
  | h == hw = Just (w, m)
  | otherwise = findStrip h rest
findStrip h (_ : rest) = findStrip h rest
