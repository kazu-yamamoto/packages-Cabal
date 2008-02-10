-- This is a quick hack for uploading packages to Hackage.
-- See http://hackage.haskell.org/trac/hackage/wiki/CabalUpload

module Hackage.Upload (check, upload) where

import Hackage.Types (Username, Password)
import Hackage.HttpUtils (proxy)

import Distribution.Simple.Utils (debug, notice, warn)
import Distribution.Verbosity (Verbosity)

import Network.Browser (BrowserAction, browse, request, 
                        Authority(..), addAuthority,
                        setOutHandler, setErrHandler, setProxy)
import Network.HTTP (Header(..), HeaderName(..), Request(..),
                     RequestMethod(..), Response(..))
import Network.URI (URI, parseURI)

import Data.Char        (intToDigit)
import Numeric          (showHex)
import System.IO        (hFlush, stdout)
import System.Random    (randomRIO)



--FIXME: how do we find this path for an arbitrary hackage server?
-- is it always at some fixed location relative to the server root?
uploadURI :: URI
Just uploadURI = parseURI "http://hackage.haskell.org/cgi-bin/hackage-scripts/protected/upload-pkg"

checkURI :: URI
Just checkURI = parseURI "http://hackage.haskell.org/cgi-bin/hackage-scripts/check-pkg"


upload :: Verbosity -> Maybe Username -> Maybe Password -> [FilePath] -> IO ()
upload verbosity mUsername mPassword paths = do

          username <- maybe (prompt "username") return mUsername
          password <- maybe (prompt "password") return mPassword
          let auth = addAuthority AuthBasic {
                       auRealm    = "Hackage",
                       auUsername = username,
                       auPassword = password,
                       auSite     = uploadURI
                     }

          flip mapM_ paths $ \path -> do
            notice verbosity $ "Uploading " ++ path ++ "... "
            handlePackage verbosity uploadURI auth path

  where prompt thing = do
          putStr ("Hackage " ++ thing ++ ": ")
          hFlush stdout
          getLine

check :: Verbosity -> [FilePath] -> IO ()
check verbosity paths = do
          flip mapM_ paths $ \path -> do
            notice verbosity $ "Checking " ++ path ++ "... "
            handlePackage verbosity checkURI (return ()) path

handlePackage :: Verbosity -> URI -> BrowserAction () -> FilePath -> IO ()
handlePackage verbosity uri auth path =
  do req <- mkRequest uri path
     p   <- proxy verbosity
     debug verbosity $ "\n" ++ show req
     (_,resp) <- browse $ do
                   setProxy p
                   setErrHandler (warn verbosity . ("http error: "++))
                   setOutHandler (debug verbosity)
                   auth
                   request req
     debug verbosity $ show resp
     case rspCode resp of
       (2,0,0) -> do notice verbosity "OK"
       (x,y,z) -> do notice verbosity $ "ERROR: " ++ path ++ ": " 
                                     ++ map intToDigit [x,y,z] ++ " "
                                     ++ rspReason resp
                     debug verbosity $ rspBody resp

mkRequest :: URI -> FilePath -> IO Request
mkRequest uri path = 
    do pkg <- readFile path
       boundary <- genBoundary
       let body = printMultiPart boundary (mkFormData path pkg)
       return $ Request {
                         rqURI = uri,
                         rqMethod = POST,
                         rqHeaders = [Header HdrContentType ("multipart/form-data; boundary="++boundary),
                                      Header HdrContentLength (show (length body)),
                                      Header HdrAccept ("text/plain")],
                         rqBody = body
                        }

genBoundary :: IO String
genBoundary = do i <- randomRIO (0x10000000000000,0xFFFFFFFFFFFFFF) :: IO Integer
                 return $ showHex i ""

mkFormData :: FilePath -> String -> [BodyPart]
mkFormData path pkg = 
    -- yes, web browsers are that stupid (re quoting)
    [BodyPart [Header hdrContentDisposition ("form-data; name=package; filename=\""++path++"\""),
               Header HdrContentType "application/x-gzip"] 
     pkg]

hdrContentDisposition :: HeaderName
hdrContentDisposition = HdrCustom "Content-disposition"

-- * Multipart, partly stolen from the cgi package.

data BodyPart = BodyPart [Header] String

printMultiPart :: String -> [BodyPart] -> String
printMultiPart boundary xs = 
    concatMap (printBodyPart boundary) xs ++ crlf ++ "--" ++ boundary ++ "--" ++ crlf

printBodyPart :: String -> BodyPart -> String
printBodyPart boundary (BodyPart hs c) = crlf ++ "--" ++ boundary ++ crlf ++ concatMap show hs ++ crlf ++ c

crlf :: String
crlf = "\r\n"