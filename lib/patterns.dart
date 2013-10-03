// Copyright 2012 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Authors:
//   Paul Brauner (polux@google.com)
//   Burak Emir (bqe@google.com)

library patterns;

import 'package:persistent/persistent.dart';

abstract class Rule {
  Rule operator | (Rule rule) => new _RuleDisjunction(this, rule);
  Option<Object> match(Object subject);
}

class Guard {
  final Function guard;

  Guard(bool guard(MatchResult res)) : this.guard = guard;

  GuardedRhs operator >> (Object rhs(MatchResult res)) =>
      new GuardedRhs(guard, rhs);
}

class GuardedRhs {
  final Function guard;
  final Function rhs;

  GuardedRhs(bool guard(MatchResult res), Object rhs(MatchResult res))
      : this.guard = guard
      , this.rhs = rhs;

  Option<Object> evaluate(MatchResult res) {
    if(guard(res)) return new Option.some(rhs(res));
    else return new Option.none();
  }
}

class _BaseRule extends Rule {
  final OPattern pattern;
  final List<GuardedRhs> rhss;

  _BaseRule(this.pattern, this.rhss);

  Option<Object> match(Object subject) {
    Option<PersistentMap<String, Object>> captured = pattern.match(subject);
    if (!captured.isDefined) return new Option.none();
    MatchResult matchResult = new MatchResult(captured.value);
    for (GuardedRhs rhs in rhss) {
      Option<Object> result = rhs.evaluate(matchResult);
      if (result.isDefined) return result;
    }
    return new Option.none();
  }

  _BaseRule operator &(GuardedRhs rhs) {
    List<GuardedRhs> newRhss = new List<GuardedRhs>.from(rhss);
    newRhss.add(rhs);
    return new _BaseRule(this.pattern, newRhss);
  }
}

class _RuleDisjunction extends Rule {
  final Rule left;
  final Rule right;
  _RuleDisjunction(this.left, this.right);
  Option<Object> match(Object subject) {
    Option<Object> leftResult = left.match(subject);
    return leftResult.isDefined ? leftResult : right.match(subject);
  }
}

abstract class OPattern<A> {
  Option<PersistentMap<String, Object>> match(A subject);

  Rule operator >> (Object rhs(MatchResult res)) {
    return new _BaseRule(this, [new GuardedRhs((_) => true, rhs)]);
  }

  _BaseRule operator & (GuardedRhs rhs) {
    return new _BaseRule(this, <GuardedRhs>[rhs]);
  }
}

class _MergeError {}

PersistentMap<String, Object> _merge(PersistentMap<String, Object> m1,
    PersistentMap<String, Object> m2) {
  return m1.union(m2, (o1, o2) {
    if (o1 == o2) return o1;
    else throw new _MergeError();
  });
}

class _ConstructorPattern<A> extends OPattern<A> {
  final List<OPattern> subPatterns;
  final Function extractor;

  _ConstructorPattern(this.subPatterns,
                      Option<List<Object>> extractor(A subject))
      : this.extractor = extractor;

  Option<PersistentMap<String, Object>> match(A subject) {
    Option<List<Object>> childrenOpt = extractor(subject);
    if (!childrenOpt.isDefined) {
      return new Option.none();
    }
    List<Object> children = childrenOpt.value;
    if (subPatterns.length != children.length) {
      throw "pattern and subject don't have same arity";
    }
    PersistentMap<String, Object> result = new PersistentMap<String, Object>();
    for (int i = 0; i < children.length; i++) {
      Option<PersistentMap<String, Object>> matchResult =
          subPatterns[i].match(children[i]);
      if (!matchResult.isDefined) {
        return new Option.none();
      }
      try {
        result = _merge(result, matchResult.value);
      } on _MergeError catch(_) {
        return new Option.none();
      }
    }
    return new Option.some(result);
  }
}

/// A pattern that can be used to alias another pattern
abstract class _VarLikePattern<A> extends OPattern<A> {
  OPattern<A> operator % (OPattern<A> pattern);
}

class _VarPattern<A> extends _VarLikePattern<A> {
  final String varName;

  _VarPattern(this.varName);

  Option<PersistentMap<String, Object>> match(A subject) =>
      new Option.some(
          new PersistentMap<String, Object>().insert(varName, subject));

  OPattern<A> operator % (OPattern<A> pattern) =>
      new _AliasPattern<A>(varName, pattern);
}

class _AliasPattern<A> extends OPattern<A> {
  final String varName;
  final OPattern<A> aliasedPattern;
  _AliasPattern(this.varName, this.aliasedPattern);
  Option<PersistentMap<String, Object>> match(A subject) {
    PersistentMap<String, Object> result =
        new PersistentMap<String, Object>().insert(varName, subject);
    Option<PersistentMap<String, Object>> matchResult =
        aliasedPattern.match(subject);
    if (!matchResult.isDefined) return new Option.none();
    try {
      result = _merge(result, matchResult.value);
      return new Option.some(result);
    } on _MergeError catch(_) {
      return new Option.none();
    }
  }
}

class _WildcardPattern<A> extends _VarLikePattern<A> {
  Option<PersistentMap<Object,Object>> match(A subject) =>
      new Option.some(new PersistentMap());

  OPattern<A> operator % (OPattern<A> pattern) => pattern;
}

class MatchFailure {}

class Matcher<A> {
  final A subject;
  Matcher(this.subject);
  Object against(Rule rule) {
    Option<Object> result = rule.match(subject);
    if (!result.isDefined) throw new MatchFailure();
    return result.value;
  }
}

class MatchResult {
  final PersistentMap<String, Object> environment;
  MatchResult(this.environment);
  operator [](String x) {
    Option<Object> res = environment.lookup(x);
    if (res.isDefined) return res.value;
    else throw "$x is undefined";
  }
}

// public API

OPattern constructor(List<OPattern> subPatterns,
                     Option<List<Object>> extractor(subject)) =>
    new _ConstructorPattern(subPatterns, extractor);

OPattern eq(Object o) => constructor([],
    (x) => x == o ? new Option.some([]) : new Option.none());

Matcher match(Object subject) => new Matcher(subject);

Guard guard(bool pred(MatchResult res)) => new Guard(pred);

bool _constTrue(_) => true; // Closures inside initializers not implemented
final Guard otherwise = guard(_constTrue);

_VarLikePattern v(String x) =>
    x == '_' ? new _WildcardPattern() : new _VarPattern(x);
