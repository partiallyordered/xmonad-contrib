-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Actions.EasyMotion
-- Copyright   :  (c) Matt Kingston <mattkingston@gmail.com>
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  mattkingston@gmail.com
-- Stability   :  unstable
-- Portability :  unportable
--
-- Provides functionality to use key chords to focus a visible window. Overlays a unique key chord
-- (a string) above each visible window and allows the user to select a window by typing that
-- chord.
-- Inspired by https://github.com/easymotion/vim-easymotion.
--
-----------------------------------------------------------------------------

module XMonad.Actions.EasyMotion (
                                   -- * Usage
                                   -- $usage
                                   selectWindow
                                 , def
                                 , EasyMotionConfig(..)
                                 ) where

import XMonad
import XMonad.StackSet as W
import XMonad.Util.Font (releaseXMF, initXMF, Align(AlignCenter), XMonadFont(..), textExtentsXMF)
import XMonad.Util.XUtils (fi, createNewWindow, paintAndWrite, deleteWindow, showWindow)
import Control.Applicative ((<$>))
import Control.Monad (when, replicateM)
import Control.Arrow ((&&&))
import Data.Maybe (isJust)
import Data.Set (fromList, toList)
import Graphics.X11.Xlib
import Graphics.X11.Xlib.Extras (getWindowAttributes, getEvent)
import qualified Data.List as L (filter, foldl', partition, find, sortOn)

-- $usage
--
-- You can use this module with the following in your @~\/.xmonad\/xmonad.hs@:
--
-- >    import XMonad.Actions.EasyMotion (selectWindow)
--
-- Then add a keybinding and an action to the selectWindow function. In this case M-f to focus:
--
-- >    , ((modm, xK_f), (selectWindow def) >>= (flip whenJust (windows . W.focusWindow)))
--
-- Similarly, to kill a window with M-f:
--
-- >    , ((modm, xK_f), (selectWindow def) >>= (flip whenJust killWindow))
--
-- Default chord keys are s,d,f,j,k,l. To customise these and display options assign
-- different values to def:
--
-- >    import XMonad.Actions.EasyMotion (selectWindow, EasyMotionConfig(..))
-- >    , ((modm, xK_f), (selectWindow def {sKeys = [xK_f, xK_d], font: "xft: Sans-40" }) >>= (flip whenJust (windows . W.focusWindow)))
--
-- You must supply at least two different keys in the sKeys list.
--
-- The font field provided is supplied directly to the initXMF function. The default is
-- "xft:Sans-100". Some example options:
--
-- >    "xft: Sans-40"
-- >    "xft: Arial-100"
-- >    "xft: Cambria-80"
--
-- Customise the overlay by supplying a function to do so. The signature is 'Position' ->
-- 'Rectangle' -> 'X' 'Rectangle'. The parameters are the height in pixels of the selection chord
-- and the rectangle of the window to be overlaid. Some are provided:
--
-- >    import XMonad.Actions.EasyMotion (selectWindow, EasyMotionConfig(..), proportional, bar, fullSize)
-- >    , ((modm, xK_f), (selectWindow def { overlayF = proportional 0.3 }) >>= (flip whenJust (windows . W.focusWindow)))
-- >    , ((modm, xK_f), (selectWindow def { overlayF = bar 0.5 }) >>= (flip whenJust (windows . W.focusWindow)))
-- >    , ((modm, xK_f), (selectWindow def { overlayF = fullSize }) >>= (flip whenJust (windows . W.focusWindow)))

-- TODO:
--  - An overlay function that creates an overlay a proportion of the width XOR height of the
--    window it's over, and with a fixed w/h proportion? E.g. overlay-height = 0.3 *
--    target-window-height; overlay-width = 0.5 * overlay-height.
--  - An overlay function that creates an overlay of a fixed w,h, aligned mid,mid, or parametrised
--    alignment?
--  - Parametrise chord generation?
--  - W.shift example; bring window from other screen to current screen? Only useful if we don't
--    show chords on current workspace.
--  - Use stringToKeysym, keysymToKeycode, keycodeToKeysym, keysymToString to take a string from
--    the user?
--  - Think a bit more about improving functionality with floating windows.
--    - currently, floating window z-order is not respected
--    - could ignore floating windows
--    - may be able to calculate the visible section of a floating window, and display the chord in
--      that space
--  - Provide an option to prepend the screen key to the easymotion keys (i.e. w,e,r)?
--  - overlay alpha
--  - Attempt to order windows left-to-right, top-to-bottom, then match select keys with them such
--    that for keys asdf the left-top-most window has key a, etc.
--  - Provide multiple lists of keys, one for each screen. This way one could learn to use certain
--    keys for certain screens. In the case of a two-screen setup, this could also be used to map
--    hands to screens.
--  - Combining the above two options should make it possible to, for any given layout and number
--    of windows, predict the key that will be required to select a given window.
--  - Delay after selection so the user can see what they've chosen? Min-delay: 0 seconds. If
--    there's a delay, perhaps keep the other windows covered briefly to naturally draw the user's
--    attention to the window they've selected? Or briefly highlight the border of the selected
--    window?
--  - Option to cover windows that will not be selected by the current chord, such that 
--  - Something unpleasant happens when the user provides only two keys (let's say f, d) for
--    chords. When they have five windows open, the following chords are generated: ddd, ddf, dfd,
--    dff, fdd. When 'f' is pressed, all chords disappear unexpectedly because we know there are no
--    other valid options. The user expects to press 'fdd'. This is an optimisation in software but
--    pretty bad for usability, as the user continues firing keys into their
--    now-unexpectedly-active window. And is of course only one concrete example of a more general
--    problem.
--    Short-term solution:
--      - Keep displaying the chord until the user has fully entered it
--    Medium-term solution:
--      - Show the shortest possible chords

-- | Associates a user window, an overlay window created by this module, a rectangle circumscribing
--   these windows, and the chord that will be used to select them
data Overlay = 
  Overlay { win     :: Window           -- The window managed by xmonad
          , overlay :: Window           -- Our window used to display the overlay
          , rect    :: Rectangle        -- The rectangle of 'overlay
          , chord   :: [KeySym]         -- The chord we'll display in the overlay
          } deriving (Show)

-- | Configuration options for EasyMotion
data EasyMotionConfig =
  EMConf { txtCol      :: String                             -- ^ Color of the text displayed
         , bgCol       :: String                             -- ^ Color of the window overlaid
         , overlayF    :: Position -> Rectangle -> Rectangle -- ^ Function to generate overlay rectangle
         , borderCol   :: String                             -- ^ Color of the overlay window borders
         , sKeys       :: [[KeySym]]                         -- ^ Keys to use for window selection
         , cancelKey   :: KeySym                             -- ^ Key to use to cancel selection
         , font        :: String                             -- ^ Font for selection characters (passed to initXMF)
         , borderPx    :: Int                                -- ^ Width of border in pixels
         , maxChordLen :: Int                                -- ^ Maximum chord length. Use 0 for no maximum.
         }

{- TODO: remove this awkward namespacing; let the user add namespacing on import if they want -}
instance Default EasyMotionConfig where
  def =
    EMConf { txtCol      = "#ffffff"
           , bgCol       = "#000000"
           , overlayF    = proportional 0.3
           , borderCol   = "#ffffff"
           , sKeys       = [[xK_s, xK_d, xK_f, xK_j, xK_k, xK_l]]
           , cancelKey   = xK_q
           , font        = "xft: Sans-100"
           , borderPx    = 1
           , maxChordLen = 0
           }

-- | Use to create overlay windows the same size as the window they select
fullSize :: Position -> Rectangle -> Rectangle
fullSize th = id

-- | Use to create overlay windows a proportion of the size of the window they select
proportional :: RealFrac f => f -> Position -> Rectangle -> Rectangle
proportional f th r = do
  let newW = round $ f * fi (rect_width r)
      newH = round $ f * fi (rect_height r)
  Rectangle { rect_width  = newW
            , rect_height = newH
            , rect_x      = rect_x r + fi (rect_width r - newW) `div` 2
            , rect_y      = rect_y r + fi (rect_height r - newH) `div` 2 }

-- | Use to create overlay windows the minimum size to contain their key chord
textSize :: Position -> Rectangle -> Rectangle
textSize th r = Rectangle { rect_width  = fi th
                          , rect_height = fi th
                          , rect_x      = rect_x r + (fi (rect_width r) - fi th) `div` 2
                          , rect_y      = rect_y r + (fi (rect_height r) - fi th) `div` 2 }

-- | Use to create overlay windows the full width of the window they select, the minimum height to
--   contain their chord, and a proportion of the distance from the top of the window they select
bar :: RealFrac f => f -> Position -> Rectangle -> Rectangle
bar f th r = Rectangle { rect_width  = rect_width r
                       , rect_height = fi th
                       , rect_x      = rect_x r
                       , rect_y      = rect_y r + round (f' * (fi (rect_height r) - fi th)) }
                         -- clamp f in [0,1] as other values will appear to lock up xmonad
                         -- as the overlay will be displayed off-screen
                         where f' = min 0.0 $ max f 1.0

showDummy dpy y s = do
  let r = Rectangle{ rect_width=1920, rect_height=50, rect_x=0, rect_y=y }
      bgC = "#000000"
      textC = "#ffffff"
      brW = 1
  w <- createNewWindow r Nothing "" True
  f <- initXMF $ "xft: Sans-10"
  showWindow w
  paintAndWrite w f (fi (rect_width r)) (fi (rect_height r)) (fi brW) bgC bgC textC bgC [AlignCenter] [s]

-- | Display overlay windows and chords for window selection
selectWindow :: EasyMotionConfig -> X (Maybe Window)
selectWindow EMConf { sKeys = [] } = return Nothing
selectWindow c = do
  -- make sure the key lists don't contain: duplicates, 'cancelKey, backspace
  let filterKeys = toList . fromList . L.filter (not . flip elem [cancelKey c, xK_BackSpace])
  -- case sKeys of
  --   [x] -> ()
  --   _   -> 
  -- case concatMap filterKeys (sKeys c) of
  --   -- TODO: check there're at least two keys in every list
  --   [] -> return Nothing
  --   [x] -> return Nothing
  --   filteredKeys -> do
  -- TODO: going to need to filter every key for existence in any other key list, I think. Could
  -- just concat all keys then fail on any detection of any duplicates whatsoever.
  -- guard ((length $ filterKeys $ concat (sKeys c)) == (length $ concat (sKeys c)))
  f <- initXMF $ font c
  th <- textExtentsXMF f (concatMap keysymToString (concat $ sKeys c)) >>= \(asc, dsc) -> return $ asc + dsc + 2
  XConf { theRoot = rw, display = dpy } <- ask
  XState { mapped = mappedWins, windowset = ws } <- get
  let currentW = W.stack . W.workspace . W.current $ ws
      -- TODO: sort wins
      keyWinPairs = zip (sKeys c) $ case sKeys c of
               [x] -> [toList mappedWins]
               _ -> map (L.filter (`elem` mappedWins) . W.integrate' . W.stack . W.workspace) sortedScreens
                 where
                   sortedScreens = L.sortOn ((rect_x &&& rect_y) . screenRect . W.screenDetail) (W.current ws : W.visible ws)
      chordWins = concatMap (\(ks, ws) -> appendChords (maxChordLen c) ks ws) keyWinPairs
      displayF = displayOverlay f (bgCol c) (borderCol c) (txtCol c) (borderPx c)
      appendOverlay (w, chord) = do
        wAttrs <- io $ getWindowAttributes dpy w
        let r = overlayF c th $ makeRect wAttrs
        o <- createNewWindow r Nothing "" True
        return Overlay { rect=r, overlay=o, chord=chord, win=w }
  overlays <- sequence $ fmap appendOverlay $ chordWins
  status <- io $ grabKeyboard dpy rw True grabModeAsync grabModeAsync currentTime
  case status of
    grabSuccess -> do
      -- handle keyboard input
      resultWin <- handle dpy displayF (cancelKey c) overlays []
      io $ ungrabKeyboard dpy currentTime
      mapM_ (deleteWindow . overlay) overlays
      io $ sync dpy False
      releaseXMF f
      case resultWin of
        Selected o -> return . Just $ win o
        _ -> whenJust currentW (windows . W.focusWindow . W.focus) >> return Nothing -- return focus correctly
    _ -> return Nothing

-- | Take a list of overlays lacking chords, return a list of overlays with key chords
appendChords :: Int -> [KeySym] -> [Window] -> [(Window, [KeySym])]
appendChords _ [] _ = []
appendChords maxLen keys wins =
  zip wins chords
    where
      chords = replicateM chordLen keys
      tempLen = -((-(length wins)) `div` (length keys))
      chordLen = if maxLen <= 0 then tempLen else min tempLen maxLen

-- | Get a key event, translate it to an event type and keysym
event d = allocaXEvent $ \e -> do
  maskEvent d (keyPressMask .|. keyReleaseMask) e
  KeyEvent {ev_event_type = t, ev_keycode = c} <- getEvent e
  s <- keycodeToKeysym d c 0
  return (t, s)

-- | A three-state result for handling user-initiated selection cancellation, successful selection,
--   or backspace.
data HandleResult a = Exit | Selected a | Backspace
-- | Handle key press events for window selection.
handle :: Display -> (Overlay -> X()) -> KeySym -> [Overlay] -> [Overlay] -> X (HandleResult Overlay)
handle dpy drawFn cancelKey fgOverlays bgOverlays = do
  let redraw = mapM (mapM_ drawFn) [fgOverlays, bgOverlays]
  let retryBackspace x =
        case x of
          Backspace -> do redraw
                          handle dpy drawFn cancelKey fgOverlays bgOverlays
          _ -> return x
  redraw
  (t, s) <- io $ event dpy
  case () of
    () | t == keyPress && s == cancelKey -> return Exit
    () | t == keyPress && s == xK_BackSpace -> return Backspace
    () | t == keyPress && isJust (L.find ((== s) . head .chord) fgOverlays) ->
      case fg of
        [x] -> return $ Selected x
        _   -> handle dpy drawFn cancelKey (trim fg) (clear bg) >>= retryBackspace
      where
        (fg, bg) = L.partition ((== s) . head . chord) fgOverlays
        trim = map (\o -> o { chord = tail $ chord o })
        clear = map (\o -> o { chord = [] })
    () -> handle dpy drawFn cancelKey fgOverlays bgOverlays

-- | Get the circumscribing rectangle of the given X window
getWindowRect :: Display -> Window -> X Rectangle
getWindowRect dpy w = io $ fmap makeRect (getWindowAttributes dpy w)
  where
    makeRect :: WindowAttributes -> Rectangle
    makeRect wa = Rectangle (fi (wa_x wa)) (fi (wa_y wa)) (fi (wa_width wa)) (fi (wa_height wa))

makeRect :: WindowAttributes -> Rectangle
makeRect wa = Rectangle (fi (wa_x wa)) (fi (wa_y wa)) (fi (wa_width wa)) (fi (wa_height wa))

-- | Display an overlay with the provided formatting
displayOverlay :: XMonadFont -> String -> String -> String -> Int -> Overlay -> X ()
displayOverlay f bgC brC textC brW Overlay { overlay = w, rect = r, chord = c } = do
  showWindow w
  paintAndWrite w f (fi (rect_width r)) (fi (rect_height r)) (fi brW) bgC brC textC bgC [AlignCenter] [L.foldl' (++) "" $ map keysymToString c]

