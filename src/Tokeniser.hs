{-# OPTIONS_GHC -Wall #-} {-# LANGUAGE RankNTypes, BangPatterns, LambdaCase, ApplicativeDo, OverloadedStrings, ScopedTypeVariables, DeriveFunctor, DeriveTraversable, FlexibleInstances, FlexibleContexts #-}
module Tokeniser (Token(runToken)
                 ,LinePos(..),ScanResult(..),Scannable(..)
                 ,isQuoted,isUnquoted,exactMatch
                 ,scanPartitioned
                 ,partitionedSuccess -- same, but as a maybe type
                 ,showPos
                 ) where
import Helpers

-- Tokenizer.
-- We want expressions like "3+-4" to be interpretable as "(+) 3 (- 4)",
-- but also as "(+-) 3 4".
-- This can be achieved by turning "3+-4" into four separate tokens.
-- The mixfix operation +- then has an empty-only place between the + and the -.
-- Parsing "3+ -4" could not result in a match on the mixfix,
-- since we disallow the space between + and - in the parser.
-- 
-- On the other hand, we keep potential (unquoted) variable-names together,
-- so something like 4ab3_X_ is ONLY interpretable as a single token.
-- Consequently, a token can be:
-- # A single character not in the set [A-Za-z0-9_]
-- # A sequence of characters from the set [A-Za-z0-9_]
-- To allow for fancy texts, we distinguish two special token-cases:
-- # Quoted strings following Haskell conventions,
--   i.e. "strings that may have \"quotes\" inside like this string".
-- # LaTeX compatible strings,
--   which are strings starting with \ followed by any sequence of characters,
--   except for those characters in the String "[]{}()<>,;.\\ \t\r\n"
--   (i.e. the most common token-ending characters).
--   Note that the allowed characters are not necessarily valid in LaTeX
-- Any string can be tokenised as a single Quoted string,
--   though not every string can be tokenised as a LaTeX string.
-- We also allow for comments:
-- # Nested comments using {- this -} Haskell-syntax
--   (no mandatory whitespace before/after the - sign, but recommended)
-- # comments to the end of line, again haskell-like
--   (no mandatory whitespace after the --, but recommended)
-- We keep whitespace in our first parse, which makes for seven kinds of pre-tokens in total:

data PreToken a = SingleCharacter a
                | CharacterSequence a
                | QuotedString_Pre a -- characters like " no longer escaped
                | LaTeXString a
                | MultiLineComment [a]
                | EndOfLineComment a
                | WhiteSpace a
                deriving (Show,Functor)
-- PreToken allows us to easily reconstruct the original source,
-- but all the supporting characters are still required

data LinePos a = LinePos {line:: !Int, pos:: !Int, runLinePos:: !a}
                 deriving (Functor,Ord,Eq, Foldable, Traversable)

-- LaTeX-style tokens always start with a \, so they do not overlap with the other set of tokens.
-- Quoted strings are parsed without their first and final quote and get a separate constructor.
-- This gives us two kinds of tokens:

data Token a = QuotedString {runToken::a} | NonQuoted {runToken::a}
             deriving (Eq, Ord, Functor)

exactMatch :: forall t y. (Eq y, Alternative t)
           => (forall v. (Token (LinePos y, Bool) -> Maybe v)
               -> t v)
           -> [Token (y, Bool)] -> t [Token (LinePos y)]
exactMatch terminal mpt = go mpt
    where
      go :: [Token (y, Bool)] -> t [Token (LinePos y)]
      go [NonQuoted (a',b)]
        = m b (\v' -> [v']) a'
      go (NonQuoted (a',b) : as)
        = m b (\v' -> (:) v') a' <*> go as
      go _ = Helpers.empty -- Invalid token / no match!
      m :: Bool -> (Token (LinePos y) -> a)
        -> y -> t a
      m b' f a'
        = terminal (\v' -> case v' of
                           {NonQuoted (v,b)
                              | runLinePos v == a' && (not b' || b)
                                         -> Just (f (NonQuoted v))
                           ; _ -> Nothing})

instance Show a => Show (Token a) where
  show (QuotedString a) = show (show a)
  show (NonQuoted a) = show a           

instance (Scannable a, IsString a) => IsString (Token a) where
  fromString v = case scanPartitioned id (fromString v) of
       ([v'],LinePos _ _ Success) -> (fmap (runLinePos . fst) v')
       _ -> QuotedString (fromString v)

isQuoted :: Token t -> Bool
isQuoted QuotedString{} = True
isQuoted NonQuoted{} = False
isUnquoted :: Scannable t => Token t -> Bool
isUnquoted s
  = case tokenToPreToken s of
      CharacterSequence _ -> True
      _ -> False

data NonParsed a = MultiLine [a] | EndOfLine a | NPspace a
data ScanResult a = Success | ExpectClosingComment | ExpectClosingQuote
                  | InvalidChar (LinePos a) deriving (Functor)

class Scannable a where
  scan :: LinePos a -> ([LinePos (PreToken a)],LinePos (ScanResult a))

instance Scannable a => Scannable (LinePos a,Bool) where
  scan (LinePos a b (v,r))
   = let (r1,LinePos c d rm) = scan v
     in (fmap incr r1, LinePos c d (fmap wrap rm))
   where
     wrap v' = (LinePos a b v',r)
     incr :: LinePos (PreToken a) -> LinePos (PreToken (LinePos a, Bool))
     incr (LinePos c d x)
           = if c>0 then LinePos (a+c) d (fmap wrap x)
             else LinePos a (d+b) (fmap wrap x)

splitPreToken :: PreToken a -> Either (Token a) (NonParsed a)
splitPreToken (SingleCharacter a   ) = Left (NonQuoted a)
splitPreToken (CharacterSequence a ) = Left (NonQuoted a)
splitPreToken (QuotedString_Pre a  ) = Left (QuotedString a)
splitPreToken (LaTeXString a       ) = Left (NonQuoted a)
splitPreToken (MultiLineComment as ) = Right (MultiLine as)
splitPreToken (EndOfLineComment a  ) = Right (EndOfLine a)
splitPreToken (WhiteSpace a        ) = Right (NPspace a)
tokenToPreToken :: Scannable a => Token a -> PreToken a
tokenToPreToken (QuotedString a) = QuotedString_Pre a
tokenToPreToken (NonQuoted a)
  = case scan (LinePos 0 0 a) of
     ([p],LinePos _ _ Success) -> runLinePos p
     _ -> error "Invalid NonQuoted token. The token should never have been created this way."
     -- TODO: this makes it that Token is not a functor

instance Scannable Text where
  scan (LinePos lineNr colNr p)
   | isPrefixOf "{-" p = case completeComment 2 1 p (Helpers.drop 2 p) of
                           Nothing -> done ExpectClosingComment
                           Just (h,t) -> simple (h,t) mlc
   | isPrefixOf "--" p = simple (Helpers.break ((==) '\n') p)
                                (EndOfLineComment . Helpers.drop 2)
   | isPrefixOf "\"" p = case completeQuoted lineNr (colNr + 1)
                                             "" (Helpers.tail p) of
                              Left e -> done e
                              Right (h,t) -> cont (QuotedString_Pre h) t
   | isPrefixOf "\\" p = let isSep v = elem v sepChars
                             sepChars :: String
                             sepChars = "[]{}()<>,;.\\ \t\r\n"
                             (h,t) = Helpers.break isSep (Helpers.tail p)
                         in cont (LaTeXString (mappend (Helpers.take 1 p) h))
                                 (incrPos (LinePos lineNr (colNr+1) t) h)
   | tnull p = done Success
   | isSpace (Helpers.head p) = simple (Helpers.span isSpace p) WhiteSpace
   | isSeqChar (Helpers.head p) = simple (Helpers.span isSeqChar p)
                                      CharacterSequence
   | otherwise = cont (SingleCharacter (Helpers.take 1 p))
                      (LinePos lineNr (colNr+1) (Helpers.drop 1 p))
   where done e = ([],LinePos lineNr colNr e)
         isSeqChar c = isAlphaNum c || c == '-' || c == '_'
         cont r newTail = let (scanTail,scanRest) = scan newTail
                            in (LinePos lineNr colNr r:scanTail, scanRest)
         simple (h,t) f = cont (f h) (incrPos (LinePos lineNr colNr t) h)
         mlc = MultiLineComment . Helpers.lines . Helpers.drop 2 . dropEnd 2
         completeComment :: Int -> Int -> Text -> Text -> Maybe (Text, Text)
         completeComment !pos' 0 str _ = Just (Helpers.splitAt (fromIntegral pos') str)
         completeComment !pos' lvl str remainder
           | tnull remainder = Nothing -- expecting closing comment - }
           | otherwise = let (h,t) = Helpers.break ((==) '-') remainder
              in case (isSuffixOf "{" h,stripPrefix "-}" t) of
                 (True,_) -> completeComment (pos'+tlength h+1)
                                             (lvl+1) str (Helpers.drop 1 t)
                 (_,Just r)->completeComment (pos'+tlength h+2)
                                             (lvl-1) str r
                 (_,_)    -> completeComment (pos'+tlength h+1)
                                             lvl str (Helpers.drop 1 t)
         completeQuoted !l !c res remainder
           = let (h,t) = Helpers.break (\v -> v == '\\' || v == '"'
                                    || v == '\n') remainder
                 c' = c + (tlength h)
              in case (tnull t,Helpers.head t) of
                  (False,'"') -> Right (mappend res h,LinePos l (c'+1) (Helpers.tail t))
                  (False,'\\')
                   -> let truncT = Helpers.take 9 t in
                      case readLitChar (unpack truncT) of -- \NUL is the longest possible string (or one of them), which is why we can take 4. Truncating is probably asymptotically faster: even though unpack produces a lazy 'rest', we still need to get the length of 'rest' to calculate 'siz'. Note that we cannot get the length of r, since '\^C'='\ETX', and there are more characters like that
                        [(r,rest)]
                         -> let siz = tlength truncT - Prelude.length rest
                            in completeQuoted l (c'+siz)
                                                (mappend res (snoc h r))
                                                (Helpers.drop (fromIntegral siz) t)
                        _ -> Left (InvalidChar (LinePos l c' truncT))
                  _ -> Left ExpectClosingQuote -- expecting closing quote

incrPos :: forall a. LinePos a -> Text -> LinePos a
incrPos orig@(LinePos l p' v) ps
  = case split (=='\n') ps of
     [] -> orig
     [r] -> LinePos l (p' + tlength r) v
     o -> LinePos (l + fromIntegral (Prelude.length o) - 1)
                  (tlength (Prelude.last o)) v

partitionTokens :: Bool -> [LinePos (PreToken a)] -> [Token (LinePos a, Bool)]
partitionTokens b (LinePos i j a:as)
 = case splitPreToken a of
     Left v -> fmap (\v' -> (LinePos i j v',b)) v:partitionTokens True as
     Right _ -> partitionTokens False as
partitionTokens _ [] = []

partitionedSuccess :: Scannable y => y -> Maybe [Token (y, Bool)]
partitionedSuccess a = case scan (LinePos 0 0 a) of
          (scanned,LinePos _ _ Success)
            -> Just (Prelude.map (fmap (first runLinePos))
                                 (partitionTokens False scanned))
          _ -> Nothing

scanPartitioned :: Scannable a
                => ([Token (LinePos a, Bool)] -> t)
                -> a
                -> (t, LinePos (ScanResult a))
scanPartitioned f inp
 = (f (partitionTokens False scanned),scanResult)
 where
    (scanned,scanResult) = scan (LinePos 0 0 inp)

showPos :: (a->String)-> LinePos a -> [Char]
showPos s (LinePos r c a) = s a++" on "++show (r+1)++":"++show (c+1)