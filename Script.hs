module Script (initialize, load) where

import Foreign.Storable as S
import Foreign.Ptr
import Foreign.C.Types
import Control.Monad

import Scripting.Lua
import qualified Video
import qualified Audio
--import qualified Graphics.UI.SDL.Mixer.Music as Audio
--import qualified Graphics.UI.SDL.Mixer as Audio
import qualified Graphics.Rendering.OpenGL as GL

import App

data LuaError = LuaSuccess | LuaErrRun | LuaErrSyntax | LuaErrMem | LuaErrErr deriving Show

toLuaError :: Int -> LuaError
toLuaError 0 = LuaSuccess
toLuaError 2 = LuaErrRun
toLuaError 3 = LuaErrSyntax
toLuaError 4 = LuaErrMem
toLuaError 6 = LuaErrErr

onError :: Int -> (LuaError -> IO ()) -> IO ()
onError 0 _ = return ()
onError e proc = proc $ toLuaError e

initialize :: Video.Video -> Audio.Audio -> IO LuaState
initialize _ audio = do
    l <- newstate
    openlibs l
    doExport l audio
    return l

load :: App a -> IO ()
load app = do
    setScriptStatus app ScriptReady

    let l = appScript app
    pushcfunction l =<< wrap errorfunc
    err <- loadfile l "main.lua"

    onError err (handler l)

    when (err == 0) $ do
        newtable l
        newtable l
        getfield l globalsindex "_G"
        setfield l (-2) "__index"
        setmetatable l (-2)
        pushvalue l (-1)
        setfenv l (-3)

        setglobal l "user"
        
        printInfoStatus app "running main.lua"
    
        pcall l 0 0 (-2) >>= flip onError (handler l)
    where
        handler l err = do
            printInfoStatus app =<< tostring l (-1)
            print err
            setScriptStatus app ScriptInvalid

doExport :: LuaState -> Audio.Audio -> IO ()
doExport l audio = do
    checkV 1 =<< newmetatable l "Image" -- returns 0
    pop l 1
    registerhsfunction l "loadImage" Video.loadImage
    registerhsfunction l "drawImage" Video.drawImage
    registerhsfunction l "drawImageOrig" Video.drawImageOrig
    registerhsfunction l "drawImageEx" Video.drawImageEx
    registerhsfunction l "drawImageRgn" Video.drawImageRgn
    registerhsfunction l "getImageWidth" $ mkIO Video.imageWidth
    registerhsfunction l "getImageHeight" $ mkIO Video.imageHeight
    registerhsfunction l "_drawText" $ Video.drawText

    registerhsfunction l "playMusic" (Audio.playMusic audio)

    where
        mkIO :: (a -> b) -> a -> IO b
        mkIO = (return.)


foreign import ccall "wrapper"
    wrap :: LuaCFunction -> IO (FunPtr LuaCFunction) -- Never free them

errorfunc :: LuaCFunction
errorfunc l = do
    pushvalue l 1
    return 1

checkV :: Eq a => a -> a -> IO ()
checkV expected actual = when (expected /= actual) $ putStrLn "Assertion: Return value Not Matched!"

instance Storable Video.Image where
    peek p = do
        name <- S.peek $ castPtr p
        width <- S.peek $ plusPtr p $ sizeOf name
        height <- S.peek $ plusPtr p $ sizeOf name + sizeOf width
        return $ Video.Image (GL.TextureObject name) width height
    poke p img = do
        let Video.Image (GL.TextureObject texId) width height = img
        poke (castPtr p) texId
        poke (p `plusPtr` sizeOf texId) width
        poke (p `plusPtr` sizeOf texId `plusPtr` sizeOf width) height
        return ()
    sizeOf (Video.Image (GL.TextureObject texId) width height) = sizeOf texId + sizeOf width + sizeOf height
    alignment _ = 4

instance StackValue Float where
    push l a = pushnumber l (realToFrac a)
    peek l n = liftM (Just . realToFrac) $ tonumber l n
    valuetype _ = TNUMBER

instance StackValue Video.Image where
    push l a = do
        p <- newuserdata l $ sizeOf a
        poke (castPtr p) a
        setClass l "Image"

    peek = checkUData "Image"
    valuetype _ = TUSERDATA

checkUData :: (StackValue a, Storable a) => String -> LuaState -> Int -> IO (Maybe a)
checkUData tname l argn =
    getmetatable l argn >>= flip success (do
        getfield l registryindex tname
        eq <- equal l (-1) (-2)
        pop l 2

        success eq $ liftM Just $ touserdata l argn >>= S.peek)

setClass l className= do
    getfield l registryindex className
    setmetatable l (-2)

success :: MonadPlus m => Bool -> IO (m a) -> IO (m a)
success True proc = proc
success False _ = return mzero