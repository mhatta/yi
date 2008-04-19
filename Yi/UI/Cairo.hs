{-# LANGUAGE BangPatterns, ExistentialQuantification #-}

-- Copyright (c) 2007, 2008 Jean-Philippe Bernardy

-- | This module defines a user interface implemented using gtk2hs and cairo for text rendering.

module Yi.UI.Cairo (start) where

import Prelude hiding (error, sequence_, elem, mapM_, mapM, concatMap)
import Yi.Accessor
import Yi.Buffer.Implementation (inBounds, Update(..), UIUpdate(..))
import Yi.Buffer
import Yi.Buffer.HighLevel (setSelectionMarkPointB)
import qualified Yi.Editor as Editor
import Yi.Editor hiding (windows)
import qualified Yi.Window as Window
import Yi.Window (Window)
import Yi.Event
import Yi.Keymap
import Yi.Debug
import Yi.Monad
import qualified Yi.UI.Common as Common
import Yi.UI.Common (UIConfig (..))
import Yi.Style hiding (modeline)
import qualified Yi.WindowSet as WS

import Control.Applicative
import Control.Concurrent ( yield )
import Control.Monad (ap)
import Control.Monad.Reader (liftIO, when, MonadIO)
import Control.Monad.State (runState, State, gets, modify)
import qualified Graphics.Rendering.Cairo as C 

import Data.Foldable
import Data.IORef
import Data.List ( nub, findIndex, sort )
import Data.Maybe
import Data.Traversable
import Data.Unique
import qualified Data.Map as M

import Graphics.UI.Gtk hiding ( Window, Event, Action, Point, Style )
import qualified Graphics.UI.Gtk as Gtk
import qualified Graphics.UI.Gtk.ModelView as MView
import Yi.UI.Gtk.ProjectTree
import Yi.UI.Gtk.Utils
import Shim.ProjectContent

------------------------------------------------------------------------

data UI = UI { uiWindow :: Gtk.Window
             , uiBox :: VBox
             , uiCmdLine :: Label
             , tagTable :: TextTagTable
             , windowCache :: IORef [WinInfo]
             , uiActionCh :: Action -> IO ()
             , uiConfig :: Common.UIConfig
             , uiProjectStore :: MView.TreeStore ProjectItem
             }

data WinInfo = WinInfo
    {
      bufkey      :: !BufferRef         -- ^ the buffer this window opens to
    , wkey        :: !Unique
      

    , textview    :: DrawingArea
    , modeline    :: Label
    , widget      :: Box            -- ^ Top-level widget for this window.
    , isMini      :: Bool
    }

instance Show WinInfo where
    show w = "W" ++ show (hashUnique $ wkey w) ++ " on " ++ show (bufkey w)

-- | Get the identification of a window.
winkey :: WinInfo -> (Bool, BufferRef)
winkey w = (isMini w, bufkey w)

mkUI :: UI -> Common.UI
mkUI ui = Common.UI
  {
   Common.main                  = main                  ui,
   Common.end                   = end,
   Common.suspend               = windowIconify (uiWindow ui),
   Common.refresh               = refresh               ui,
   Common.prepareAction         = prepareAction         ui,
   Common.reloadProject         = reloadProject         ui
  }

mkFontDesc :: Common.UIConfig -> IO FontDescription
mkFontDesc cfg = do
  f <- fontDescriptionNew
  fontDescriptionSetFamily f "Monospace"
  case  Common.configFontSize cfg of
    Just x -> fontDescriptionSetSize f (fromIntegral x)
    Nothing -> return ()
  return f

-- | Initialise the ui
start :: Common.UIBoot
start cfg ch outCh _ed = do
  initGUI

  -- rest.
  win <- windowNew
  windowSetDefaultSize win 500 700
  --windowFullscreen win
  ico <- loadIcon "yi+lambda-fat.32.png"
  windowSetIcon win ico

  onKeyPress win (processEvent ch)

  paned <- hPanedNew

  vb <- vBoxNew False 1  -- Top-level vbox

  (projectTree, projectStore) <- projectTreeNew outCh  
  modulesTree <- treeViewNew

  tabs <- notebookNew
  set tabs [notebookTabPos := PosBottom]
  panedAdd1 paned tabs

  scrlProject <- scrolledWindowNew Nothing Nothing
  scrolledWindowAddWithViewport scrlProject projectTree
  scrolledWindowSetPolicy scrlProject PolicyAutomatic PolicyAutomatic
  notebookAppendPage tabs scrlProject "Project"

  scrlModules <- scrolledWindowNew Nothing Nothing
  scrolledWindowAddWithViewport scrlModules modulesTree
  scrolledWindowSetPolicy scrlModules PolicyAutomatic PolicyAutomatic
  notebookAppendPage tabs scrlModules "Modules"

  vb' <- vBoxNew False 1
  panedAdd2 paned vb'

  set win [ containerChild := vb ]
  onDestroy win mainQuit

  cmd <- labelNew Nothing
  set cmd [ miscXalign := 0.01 ]
  widgetModifyFont cmd =<< Just <$> mkFontDesc cfg

  set vb [ containerChild := paned,
           containerChild := cmd,
           boxChildPacking cmd  := PackNatural ]

  -- use our magic threads thingy (http://haskell.org/gtk2hs/archives/2005/07/24/writing-multi-threaded-guis/)
  timeoutAddFull (yield >> return True) priorityDefaultIdle 50

  widgetShowAll win

  bufs <- newIORef M.empty
  wc <- newIORef []
  tt <- textTagTableNew

  let ui = UI win vb' cmd tt wc outCh cfg projectStore

  return (mkUI ui)

main :: UI -> IO ()
main _ui =
    do logPutStrLn "GTK main loop running"
       mainGUI

instance Show Gtk.Event where
    show (Key _eventRelease _eventSent _eventTime eventModifier' _eventWithCapsLock _eventWithNumLock
                  _eventWithScrollLock _eventKeyVal eventKeyName' eventKeyChar')
        = show eventModifier' ++ " " ++ show eventKeyName' ++ " " ++ show eventKeyChar'
    show _ = "Not a key event"

instance Show Gtk.Modifier where
    show Control = "Ctrl"
    show Alt = "Alt"
    show Shift = "Shift"
    show Apple = "Apple"
    show Compose = "Compose"

processEvent :: (Event -> IO ()) -> Gtk.Event -> IO Bool
processEvent ch ev = do
  -- logPutStrLn $ "Gtk.Event: " ++ show ev
  -- logPutStrLn $ "Event: " ++ show (gtkToYiEvent ev)
  case gtkToYiEvent ev of
    Nothing -> logPutStrLn $ "Event not translatable: " ++ show ev
    Just e -> ch e
  return True

gtkToYiEvent :: Gtk.Event -> Maybe Event
gtkToYiEvent (Key {eventKeyName = keyName, eventModifier = evModifier, eventKeyChar = char})
    = fmap (\k -> Event k $ (nub $ (if isShift then filter (not . (== MShift)) else id) $ concatMap modif evModifier)) key'
      where (key',isShift) =
                case char of
                  Just c -> (Just $ KASCII c, True)
                  Nothing -> (M.lookup keyName keyTable, False)
            modif Control = [MCtrl]
            modif Alt = [MMeta]
            modif Shift = [MShift]
            modif Apple = []
            modif Compose = []
gtkToYiEvent _ = Nothing

-- | Map GTK long names to Keys
keyTable :: M.Map String Key
keyTable = M.fromList
    [("Down",       KDown)
    ,("Up",         KUp)
    ,("Left",       KLeft)
    ,("Right",      KRight)
    ,("Home",       KHome)
    ,("End",        KEnd)
    ,("BackSpace",  KBS)
    ,("Delete",     KDel)
    ,("Page_Up",    KPageUp)
    ,("Page_Down",  KPageDown)
    ,("Insert",     KIns)
    ,("Escape",     KEsc)
    ,("Return",     KEnter)
    ,("Tab",        KASCII '\t')
    ]

-- | Clean up and go home
end :: IO ()
end = mainQuit

-- | Synchronize the windows displayed by GTK with the status of windows in the Core.
syncWindows :: Editor -> UI -> [(Window, Bool)] -- ^ windows paired with their "isFocused" state.
            -> [WinInfo] -> IO [WinInfo]
syncWindows e ui (wfocused@(w,focused):ws) (c:cs)
    | Window.winkey w == winkey c = do when focused (setFocus c)
                                       return (c:) `ap` syncWindows e ui ws cs
    | Window.winkey w `elem` map winkey cs = removeWindow ui c >> syncWindows e ui (wfocused:ws) cs
    | otherwise = do c' <- insertWindowBefore e ui w c
                     when focused (setFocus c')
                     return (c':) `ap` syncWindows e ui ws (c:cs)
syncWindows e ui ws [] = mapM (insertWindowAtEnd e ui) (map fst ws)
syncWindows _e ui [] cs = mapM_ (removeWindow ui) cs >> return []

setFocus :: WinInfo -> IO ()
setFocus w = do
  logPutStrLn $ "gtk focusing " ++ show w
  hasFocus <- widgetIsFocus (textview w)
  when (not hasFocus) $ widgetGrabFocus (textview w)

removeWindow :: UI -> WinInfo -> IO ()
removeWindow i win = containerRemove (uiBox i) (widget win)

instance Show Click where
    show x = case x of
               SingleClick  -> "SingleClick "
               DoubleClick  -> "DoubleClick "
               TripleClick  -> "TripleClick "
               ReleaseClick -> "ReleaseClick"

handleClick :: UI -> WinInfo -> Gtk.Event -> IO Bool
handleClick ui w event = do
  -- logPutStrLn $ "Click: " ++ show (eventX e, eventY e, eventClick e)

  -- retrieve the clicked offset.
  let tv = textview w
  let wx = round (eventX event)
  let wy = round (eventY event)
  let (bx, by) = (0, 0)
  let p1 = 0

  -- maybe focus the window
  logPutStrLn $ "Clicked inside window: " ++ show w
  wCache <- readIORef (windowCache ui)
  let Just idx = findIndex ((wkey w ==) . wkey) wCache
      focusWindow = modifyWindows (WS.focusIndex idx)
  logPutStrLn $ "Will focus to index: " ++ show (findIndex ((wkey w ==) . wkey) wCache)

  let editorAction = do
        b <- gets $ (bkey . findBufferWith (bufkey w))
        case (eventClick event, eventButton event) of
          (SingleClick, LeftButton) -> do
              focusWindow
              withGivenBuffer0 b $ do moveTo p1 -- as a side effect we forget the prefered column
                                      setVisibleSelection True
          (SingleClick, _) -> focusWindow
          (ReleaseClick, LeftButton) -> do
            p0 <- withGivenBuffer0 b $ pointB
            if p1 == p0
              then withGivenBuffer0 b $ setVisibleSelection False
              else do txt <- withGivenBuffer0 b $ do m <- getSelectionMarkB
                                                     setMarkPointB m p1
                                                     let [i,j] = sort [p1,p0]
                                                     nelemsB (j-i) i
                      setRegE txt
          (ReleaseClick, MiddleButton) -> do
            txt <- getRegE
            withGivenBuffer0 b $ do
              pointB >>= setSelectionMarkPointB
              moveTo p1
              insertN txt

          _ -> return ()

  uiActionCh ui (makeAction editorAction)
  return True


-- | Make A new window
newWindow :: UI -> Bool -> FBuffer -> IO WinInfo
newWindow ui mini b = do
    f <- mkFontDesc (uiConfig ui)

    ml <- labelNew Nothing
    widgetModifyFont ml (Just f)
    set ml [ miscXalign := 0.01 ] -- so the text is left-justified.


    v <- drawingAreaNew
    widgetModifyFont v (Just f)

    box <- if mini
     then do
      widgetSetSizeRequest v (-1) 1

      prompt <- labelNew (Just $ name b)
      widgetModifyFont prompt (Just f)

      hb <- hBoxNew False 1
      set hb [ containerChild := prompt,
               containerChild := v,
               boxChildPacking prompt := PackNatural,
               boxChildPacking v := PackGrow]

      return (castToBox hb)
     else do
      vb <- vBoxNew False 1
      set vb [ containerChild := v,
               containerChild := ml,
               boxChildPacking ml := PackNatural]
      return (castToBox vb)


    k <- newUnique
    let win = WinInfo {
                     bufkey    = (keyB b)
                   , wkey      = k
                   , textview  = v
                   , modeline  = ml
                   , widget    = box
                   , isMini    = mini
              }
    return win

insertWindowBefore :: Editor -> UI -> Window -> WinInfo -> IO WinInfo
insertWindowBefore e i w _c = insertWindow e i w

insertWindowAtEnd :: Editor -> UI -> Window -> IO WinInfo
insertWindowAtEnd e i w = insertWindow e i w

insertWindow :: Editor -> UI -> Window -> IO WinInfo
insertWindow e i win = do
  let buf = findBufferWith (Window.bufkey win) e
  liftIO $ do w <- newWindow i (Window.isMini win) buf
              set (uiBox i) [containerChild := widget w,
                             boxChildPacking (widget w) := if isMini w then PackNatural else PackGrow]
              textview w `onButtonRelease` handleClick i w
              textview w `onButtonPress` handleClick i w
              widgetShowAll (widget w)
              return w

refresh :: UI -> Editor -> IO ()
refresh ui e = do
    let ws = Editor.windows e
    let takeEllipsis s = if length s > 132 then take 129 s ++ "..." else s
    set (uiCmdLine ui) [labelText := takeEllipsis (statusLine e)]

    cache <- readRef $ windowCache ui
    logPutStrLn $ "syncing: " ++ show ws
    logPutStrLn $ "with: " ++ show cache
    cache' <- syncWindows e ui (toList $ WS.withFocus $ ws) cache
    logPutStrLn $ "Gives: " ++ show cache'
    writeRef (windowCache ui) cache'
    forM_ cache' $ \w -> do
        let b = findBufferWith (bufkey w) e
        drawWindow <- widgetGetDrawWindow $ textview w
        (width, height) <- widgetGetSize $ textview w
        renderWithDrawable drawWindow $ display width height b


showLine h str = do
    (x, y) <- C.getCurrentPoint
    C.showText str
    C.moveTo x (y + h)
          
display :: Int -> Int -> FBuffer -> C.Render ()
display width height b = do
    C.selectFontFace "monospace" C.FontSlantNormal C.FontWeightNormal
    C.setFontSize 12 

    let (text,_) = runBufferDummyWindow b (nelemsB maxBound 0) 

    font_extents <- C.fontExtents
    let font_height  = C.fontExtentsHeight   font_extents * 1.25
        font_ascent  = C.fontExtentsAscent   font_extents
        font_descent = C.fontExtentsDescent  font_extents
        font_advance = C.fontExtentsMaxXadvance font_extents
    
    C.translate 0 font_ascent
    C.setSourceRGBA 1 1 1 1
    C.fill
    C.paint
     
    let
        start_line = 0
        line_count = ceiling (fromIntegral height / font_height)
    
    -- C.translate 20.5 (font_ascent - top + 0.5)

    let ls = take 5 $ lines $ text
    
    C.setSourceRGBA 0 0 0 1
    C.moveTo 0 (fromIntegral start_line * font_height)
    mapM_ (showLine font_height) $ ls
    


replaceTagsIn :: UI -> Point -> Point -> FBuffer -> TextBuffer -> IO ()
replaceTagsIn ui from to buf gtkBuf = do
  i <- textBufferGetIterAtOffset gtkBuf from
  i' <- textBufferGetIterAtOffset gtkBuf to
  let (styleSpans, _) = runBufferDummyWindow buf (styleRangesB (to - from) from)
  textBufferRemoveAllTags gtkBuf i i'
  forM_ (zip styleSpans (drop 1 styleSpans)) $ \((l,style),(r,_)) -> do
    f <- textBufferGetIterAtOffset gtkBuf l
    t <- textBufferGetIterAtOffset gtkBuf r
    tag <- styleToTag ui style
    textBufferApplyTag gtkBuf tag f t

applyUpdate :: TextBuffer -> Update -> IO ()
applyUpdate buf (Insert p s) = do
  i <- textBufferGetIterAtOffset buf p
  textBufferInsert buf i s

applyUpdate buf (Delete p s) = do
  i0 <- textBufferGetIterAtOffset buf p
  i1 <- textBufferGetIterAtOffset buf (p + s)
  textBufferDelete buf i0 i1

styleToTag :: UI -> Style -> IO TextTag
styleToTag ui (Style fg _bg) = do
  let fgText = colorToText fg
  mtag <- textTagTableLookup (tagTable ui) fgText
  case mtag of
    Just x -> return x
    Nothing -> do x <- textTagNew (Just fgText)
                  set x [textTagForeground := fgText]
                  textTagTableAdd (tagTable ui) x
                  return x

prepareAction :: UI -> IO (EditorM ())
prepareAction ui = do
    -- compute the heights of all windows (in number of lines)
    gtkWins <- readRef (windowCache ui)
    heights <- forM gtkWins $ \w -> return 0
    -- updates the heights of the windows
    return $ modifyWindows (\ws -> fst $ runState (mapM distribute ws) heights)

reloadProject ui fpath = do
  tree <- loadFile fpath
  loadProjectTree (uiProjectStore ui) tree

distribute :: Window -> State [Int] Window
distribute win = do
  h <- gets head
  modify tail
  return win {Window.height = h}

