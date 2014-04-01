{-# LANGUAGE OverloadedStrings #-}

-- Example:
--   $ export OAUTH_CONSUMER_KEY="your consumer key"
--   $ export OAUTH_CONSUMER_SECRET="your consumer secret"
--   $ runhaskell oauth_callback.hs

module Main where

import Web.Scotty
import qualified Network.HTTP.Types as HT
import Web.Twitter.Conduit hiding (text)
import qualified Web.Twitter.Conduit.Api as TwConduit
import Web.Authenticate.OAuth (OAuth(..), Credential(..))
import qualified Web.Authenticate.OAuth as OA
import qualified Network.HTTP.Conduit as HTTP
import qualified Data.Text.Lazy as LT
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.Map as M
import Data.Maybe
import Data.Monoid
import Data.IORef
import Control.Monad (mapM_)
import Control.Monad.Logger (runStdoutLoggingT)
import Control.Monad.IO.Class
import System.Environment
import System.IO.Unsafe

import Data.Default

callback :: String
callback = "https://localhost:3000/callback"

getTokens :: IO OAuth
getTokens = do
    consumerKey <- getEnv "OAUTH_CONSUMER_KEY"
    consumerSecret <- getEnv "OAUTH_CONSUMER_SECRET"
    return $
        twitterOAuth
        { oauthConsumerKey = S8.pack consumerKey
        , oauthConsumerSecret = S8.pack consumerSecret
        , oauthCallback = Just $ S8.pack callback
        }

type OAuthToken = S.ByteString

usersToken :: IORef (M.Map OAuthToken Credential)
usersToken = unsafePerformIO $ newIORef M.empty

takeCredential :: OAuthToken -> IORef (M.Map OAuthToken Credential) -> IO (Maybe Credential)
takeCredential k ioref =
    atomicModifyIORef ioref $ \m ->
        let (res, newm) = M.updateLookupWithKey (\_ _ -> Nothing) k m in
        (newm, res)

storeCredential :: OAuthToken -> Credential -> IORef (M.Map OAuthToken Credential) -> IO ()
storeCredential k cred ioref =
    atomicModifyIORef ioref $ \m -> (M.insert k cred m, ())

main :: IO ()
main = do
    tokens <- getTokens
    --print tokens
    cred <- HTTP.withManager $ OA.getTemporaryCredential tokens
    mapM_ print (unCredential cred)
    putStrLn "--------------------------------------------------"
    putStrLn "browse URL: http://localhost:3000/signIn"
    scotty 3000 $ app tokens


--getUser :: MonadIO m => TWInfo -> String -> m User
getUser twInfo =
  runStdoutLoggingT . runTW twInfo $ call TwConduit.accountVerifyCredentials

--verify = api POST "account/verify_credentials.json"

makeMessage :: OAuth -> Credential -> S.ByteString
makeMessage tokens (Credential cred) =
    S8.intercalate "\n"
        [ "export OAUTH_CONSUMER_KEY=\"" <> oauthConsumerKey tokens <> "\""
        , "export OAUTH_CONSUMER_SECRET=\"" <> oauthConsumerSecret tokens <> "\""
        , "export OAUTH_ACCESS_TOKEN=\"" <> fromMaybe "" (lookup "oauth_token" cred) <> "\""
        , "export OAUTH_ACCESS_SECRET=\"" <> fromMaybe "" (lookup "oauth_token_secret" cred) <> "\""
        ]

app :: OAuth -> ScottyM ()
app tokens = do
    get "/callback" $ do
        temporaryToken <- param "oauth_token"
        oauthVerifier <- param "oauth_verifier"
        mcred <- liftIO $ takeCredential temporaryToken usersToken
        case mcred of
            Just cred -> do
                accessTokens <- liftIO $ HTTP.withManager $ OA.getAccessToken tokens (OA.insert "oauth_verifier" oauthVerifier cred)
                liftIO $ print accessTokens
                let twInfo = setCredential tokens accessTokens def
                user <- liftIO $ getUser twInfo
                liftIO $ print user
                let message = makeMessage tokens accessTokens
                liftIO . S8.putStrLn $ message
                text . LT.pack . S8.unpack $ message

            Nothing -> do
                status HT.status404
                text "temporary token is not found"

    get "/signIn" $ do
        cred <- liftIO $ HTTP.withManager $ OA.getTemporaryCredential tokens
        case lookup "oauth_token" $ unCredential cred of
            Just temporaryToken -> do
                liftIO $ storeCredential temporaryToken cred usersToken
                let url = OA.authorizeUrl tokens cred
                redirect $ LT.pack url
            Nothing -> do
                status HT.status500
                text "Failed to obtain the temporary token."
