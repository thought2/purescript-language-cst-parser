module PureScript.CST.Parser.Monad
  ( Parser
  , ParserResult(..)
  , ParseError
  , PositionedError
  , runParser
  , runParser'
  , take
  , fail
  , try
  , lookAhead
  , many
  , optional
  , eof
  ) where

import Prelude

import Control.Alt (class Alt, (<|>))
import Control.Lazy (class Lazy)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Lazy as Z
import Data.Maybe (Maybe(..))
import PureScript.CST.TokenStream (TokenStep(..), TokenStream)
import PureScript.CST.TokenStream as TokenStream
import PureScript.CST.Types (Comment, LineFeed, SourcePos, SourceToken)
import Unsafe.Coerce (unsafeCoerce)

foreign import data UnsafeBoundValue :: Type

data Queue c a b
  = Leaf (c a b)
  | Node (Queue c a UnsafeBoundValue) (Queue c UnsafeBoundValue b)

qappend :: forall c a x b. Queue c a x -> Queue c x b -> Queue c a b
qappend = unsafeCoerce Node

qsingleton :: forall c a b. c a b -> Queue c a b
qsingleton = Leaf

data UnconsView c a b x
  = UnconsDone (c a b)
  | UnconsMore (c a x) (Queue c x b)

unconsView :: forall c a b. Queue c a b -> UnconsView c a b UnsafeBoundValue
unconsView = uncons (unsafeCoerce UnconsDone) (unsafeCoerce UnconsMore)

uncons
  :: forall c a b r
   . (c a b -> r)
  -> (forall x. c a x -> Queue c x b -> r)
  -> Queue c a b
  -> r
uncons done more = case _ of
  Leaf a -> done a
  Node a b -> uncons' more a b

uncons'
  :: forall c a x b r
   . (forall z. c a z -> Queue c z b -> r)
  -> Queue c a x
  -> Queue c x b
  -> r
uncons' cons l r = case l of
  Leaf k -> cons (unsafeCoerce k) (unsafeCoerce r)
  Node l' r' -> uncons' cons l' (Node (unsafeCoerce r') (unsafeCoerce r))

type ParseError = String

type PositionedError =
  { position :: SourcePos
  , error :: ParseError
  }

newtype ParserK a b = ParserK (a -> Parser b)

data Parser a
  = Take (SourceToken -> Either ParseError a)
  | Eof (Array (Comment LineFeed) -> a)
  | Fail SourcePos ParseError
  | Alt (Parser a) (Parser a)
  | Try (Parser a)
  | LookAhead (Parser a)
  | Defer (Z.Lazy (Parser a))
  | Pure a
  | Bind (Parser UnsafeBoundValue) (Queue ParserK UnsafeBoundValue a)

instance functorParser :: Functor Parser where
  map f = case _ of
    Bind p queue ->
      Bind p (qappend queue (qsingleton (ParserK (Pure <<< f))))
    p ->
      Bind (unsafeCoerce p) (qsingleton (ParserK (Pure <<< unsafeCoerce f)))

instance applyParser :: Apply Parser where
  apply p1 p2 = do
    f <- p1
    a <- p2
    pure (f a)

instance applicativeParser :: Applicative Parser where
  pure = Pure

instance bindParser :: Bind Parser where
  bind p k = case p of
    Bind p' queue ->
      Bind p' (qappend queue (qsingleton (ParserK k)))
    _ ->
      Bind (unsafeCoerce p) (qsingleton (ParserK (unsafeCoerce k)))

instance monadParser :: Monad Parser

instance altParser :: Alt Parser where
  alt = Alt

instance lazyParser :: Lazy (Parser a) where
  defer = Defer <<< Z.defer

take :: forall a. (SourceToken -> Either ParseError a) -> Parser a
take = Take

fail :: forall a. SourcePos -> ParseError -> Parser a
fail = Fail

try :: forall a. Parser a -> Parser a
try = Try

lookAhead :: forall a. Parser a -> Parser a
lookAhead = LookAhead

many :: forall a. Parser a -> Parser (Array a)
many p = go []
  where
  go acc = optional p >>= case _ of
    Just more ->
      go (Array.snoc acc more)
    Nothing ->
      pure acc

optional :: forall a. Parser a -> Parser (Maybe a)
optional p = Just <$> p <|> pure Nothing

eof :: Parser (Array (Comment LineFeed))
eof = Eof identity

runParser :: forall a. TokenStream -> Parser a -> Either PositionedError a
runParser stream parser =
  case runParser' stream parser of
    ParseFail error position _ _ ->
      Left { position, error }
    ParseSucc res _ _ _ ->
      Right res

data ParserResult a
  = ParseFail ParseError SourcePos Boolean (Maybe TokenStream)
  | ParseSucc a SourcePos Boolean TokenStream

data ParserStack a
  = StkNil
  | StkAlt (ParserStack a) ParserState (Parser a)
  | StkTry (ParserStack a) ParserState
  | StkLookAhead (ParserStack a) ParserState
  | StkBinds (ParserStack a) (ParserBinds a)

type ParserBinds =
  Queue ParserK UnsafeBoundValue

type ParserState =
  { consumed :: Boolean
  , position :: SourcePos
  , stream :: TokenStream
  }

runParser' :: forall a. TokenStream -> Parser a -> ParserResult a
runParser' = \stream parser ->
  (unsafeCoerce :: ParserResult UnsafeBoundValue -> ParserResult a) $
    go StkNil
      { consumed: false
      , position: { line: 0, column: 0 }
      , stream
      }
      (unsafeCoerce parser)
  where
  go :: ParserStack UnsafeBoundValue -> ParserState -> Parser UnsafeBoundValue -> ParserResult UnsafeBoundValue
  go stack state = case _ of
    Alt a b ->
      go (StkAlt stack state b) (state { consumed = false }) a
    Try a ->
      go (StkTry stack state) state a
    LookAhead a ->
      go (StkLookAhead stack state) state a
    Bind p binds ->
      go (StkBinds stack binds) state p
    p@(Pure a) ->
      case stack of
        StkNil ->
          ParseSucc a state.position state.consumed state.stream
        StkAlt prevStack _ _ ->
          go prevStack state p
        StkTry prevStack _ ->
          go prevStack state p
        StkLookAhead prevStack prevState ->
          go prevStack prevState p
        StkBinds prevStack queue ->
          case unconsView queue of
            UnconsDone (ParserK k) ->
              go prevStack state (k a)
            UnconsMore (ParserK k) nextQueue ->
              go (StkBinds prevStack nextQueue) state (k a)
    p@(Fail errPos err) ->
      case stack of
        StkNil ->
          ParseFail err errPos state.consumed (Just state.stream)
        StkAlt prevStack prevState prev ->
          if state.consumed then
            go prevStack state p
          else
            go prevStack prevState prev
        StkTry prevStack prevState ->
          go prevStack (state { consumed = prevState.consumed }) p
        StkLookAhead prevStack prevState ->
          go prevStack prevState p
        StkBinds prevStack _ ->
          go prevStack state p
    Take k ->
      case TokenStream.step state.stream of
        TokenError errPos _ errStream ->
          ParseFail "Failed to parse token" errPos state.consumed errStream
        TokenEOF errPos _ ->
          go stack state (Fail errPos "Unexpected EOF")
        TokenCons tok nextPos nextStream ->
          case k tok of
            Left err ->
              go stack state (Fail tok.range.start err)
            Right a ->
              go stack { consumed: true, position: nextPos, stream: nextStream } (Pure a)
    Eof k ->
      case TokenStream.step state.stream of
        TokenError errPos _ errStream ->
          ParseFail "Failed to parse token" errPos state.consumed errStream
        TokenEOF eofPos comments ->
          go stack (state { consumed = true, position = eofPos }) (Pure (k comments))
        TokenCons tok _ _ ->
          go stack state (Fail tok.range.start "Expected EOF")
    Defer z ->
      go stack state (Z.force z)