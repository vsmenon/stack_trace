// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// VM chain tests can rely on stronger guarantees about the contents of the
// stack traces than dart2js.
@TestOn('dart-vm')

import 'dart:async';

import 'package:stack_trace/stack_trace.dart';
import 'package:test/test.dart';

import '../utils.dart';
import 'utils.dart';

void main() {
  group('capture() with onError catches exceptions', () {
    test('thrown synchronously', () {
      return captureFuture(() => throw 'error')
          .then((chain) {
        expect(chain.traces, hasLength(1));
        expect(chain.traces.single.frames.first,
            frameMember(startsWith('main')));
      });
    });

    test('thrown in a microtask', () {
      return captureFuture(() => inMicrotask(() => throw 'error'))
          .then((chain) {
        // Since there was only one asynchronous operation, there should be only
        // two traces in the chain.
        expect(chain.traces, hasLength(2));

        // The first frame of the first trace should be the line on which the
        // actual error was thrown.
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));

        // The second trace should describe the stack when the error callback
        // was scheduled.
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('thrown in a one-shot timer', () {
      return captureFuture(() => inOneShotTimer(() => throw 'error'))
          .then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
      });
    });

    test('thrown in a periodic timer', () {
      return captureFuture(() => inPeriodicTimer(() => throw 'error'))
          .then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('thrown in a nested series of asynchronous operations', () {
      return captureFuture(() {
        inPeriodicTimer(() {
          inOneShotTimer(() => inMicrotask(() => throw 'error'));
        });
      }).then((chain) {
        expect(chain.traces, hasLength(4));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
        expect(chain.traces[3].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('thrown in a long future chain', () {
      return captureFuture(() => inFutureChain(() => throw 'error'))
          .then((chain) {
        // Despite many asynchronous operations, there's only one level of
        // nested calls, so there should be only two traces in the chain. This
        // is important; programmers expect stack trace memory consumption to be
        // O(depth of program), not O(length of program).
        expect(chain.traces, hasLength(2));

        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inFutureChain'))));
      });
    });

    test('thrown in new Future()', () {
      return captureFuture(() => inNewFuture(() => throw 'error'))
          .then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));

        // The second trace is the one captured by
        // [StackZoneSpecification.errorCallback]. Because that runs
        // asynchronously within [new Future], it doesn't actually refer to the
        // source file at all.
        expect(chain.traces[1].frames,
            everyElement(frameLibrary(isNot(contains('chain_test')))));

        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inNewFuture'))));
      });
    });

    test('thrown in new Future.sync()', () {
      return captureFuture(() {
        inMicrotask(() => inSyncFuture(() => throw 'error'));
      }).then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inSyncFuture'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('multiple times', () {
      var completer = new Completer();
      var first = true;

      Chain.capture(() {
        inMicrotask(() => throw 'first error');
        inPeriodicTimer(() => throw 'second error');
      }, onError: (error, chain) {
        try {
          if (first) {
            expect(error, equals('first error'));
            expect(chain.traces[1].frames,
                contains(frameMember(startsWith('inMicrotask'))));
            first = false;
          } else {
            expect(error, equals('second error'));
            expect(chain.traces[1].frames,
                contains(frameMember(startsWith('inPeriodicTimer'))));
            completer.complete();
          }
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      });

      return completer.future;
    });

    test('passed to a completer', () {
      var trace = new Trace.current();
      return captureFuture(() {
        inMicrotask(() => completerErrorFuture(trace));
      }).then((chain) {
        expect(chain.traces, hasLength(3));

        // The first trace is the trace that was manually reported for the
        // error.
        expect(chain.traces.first.toString(), equals(trace.toString()));

        // The second trace is the trace that was captured when
        // [Completer.addError] was called.
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('completerErrorFuture'))));

        // The third trace is the automatically-captured trace from when the
        // microtask was scheduled.
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('passed to a completer with no stack trace', () {
      return captureFuture(() {
        inMicrotask(() => completerErrorFuture());
      }).then((chain) {
        expect(chain.traces, hasLength(2));

        // The first trace is the one captured when [Completer.addError] was
        // called.
        expect(chain.traces[0].frames,
            contains(frameMember(startsWith('completerErrorFuture'))));

        // The second trace is the automatically-captured trace from when the
        // microtask was scheduled.
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('passed to a stream controller', () {
      var trace = new Trace.current();
      return captureFuture(() {
        inMicrotask(() => controllerErrorStream(trace).listen(null));
      }).then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces.first.toString(), equals(trace.toString()));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('controllerErrorStream'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('passed to a stream controller with no stack trace', () {
      return captureFuture(() {
        inMicrotask(() => controllerErrorStream().listen(null));
      }).then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames,
            contains(frameMember(startsWith('controllerErrorStream'))));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('and relays them to the parent zone', () {
      var completer = new Completer();

      runZoned(() {
        Chain.capture(() {
          inMicrotask(() => throw 'error');
        }, onError: (error, chain) {
          expect(error, equals('error'));
          expect(chain.traces[1].frames,
              contains(frameMember(startsWith('inMicrotask'))));
          throw error;
        });
      }, onError: (error, chain) {
        try {
          expect(error, equals('error'));
          expect(chain, new isInstanceOf<Chain>());
          expect(chain.traces[1].frames,
              contains(frameMember(startsWith('inMicrotask'))));
          completer.complete();
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      });

      return completer.future;
    });
  });

  test('capture() without onError passes exceptions to parent zone', () {
    var completer = new Completer();

    runZoned(() {
      Chain.capture(() => inMicrotask(() => throw 'error'));
    }, onError: (error, chain) {
      try {
        expect(error, equals('error'));
        expect(chain, new isInstanceOf<Chain>());
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });

    return completer.future;
  });

  group('current() within capture()', () {
    test('called in a microtask', () {
      var completer = new Completer();
      Chain.capture(() {
        inMicrotask(() => completer.complete(new Chain.current()));
      });

      return completer.future.then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('called in a one-shot timer', () {
      var completer = new Completer();
      Chain.capture(() {
        inOneShotTimer(() => completer.complete(new Chain.current()));
      });

      return completer.future.then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
      });
    });

    test('called in a periodic timer', () {
      var completer = new Completer();
      Chain.capture(() {
        inPeriodicTimer(() => completer.complete(new Chain.current()));
      });

      return completer.future.then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('called in a nested series of asynchronous operations', () {
      var completer = new Completer();
      Chain.capture(() {
        inPeriodicTimer(() {
          inOneShotTimer(() {
            inMicrotask(() => completer.complete(new Chain.current()));
          });
        });
      });

      return completer.future.then((chain) {
        expect(chain.traces, hasLength(4));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inMicrotask'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
        expect(chain.traces[3].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('called in a long future chain', () {
      var completer = new Completer();
      Chain.capture(() {
        inFutureChain(() => completer.complete(new Chain.current()));
      });

      return completer.future.then((chain) {
        expect(chain.traces, hasLength(2));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('inFutureChain'))));
      });
    });
  });

  test('current() outside of capture() returns a chain wrapping the current '
      'trace', () {
    // The test runner runs all tests with chains enabled.
    return Chain.disable(() {
      var completer = new Completer();
      inMicrotask(() => completer.complete(new Chain.current()));

      return completer.future.then((chain) {
        // Since the chain wasn't loaded within [Chain.capture], the full stack
        // chain isn't available and it just returns the current stack when
        // called.
        expect(chain.traces, hasLength(1));
        expect(chain.traces.first.frames.first,
            frameMember(startsWith('main')));
      });
    });
  });

  group('forTrace() within capture()', () {
    test('called for a stack trace from a microtask', () {
      return Chain.capture(() {
        return chainForTrace(inMicrotask, () => throw 'error');
      }).then((chain) {
        // Because [chainForTrace] has to set up a future chain to capture the
        // stack trace while still showing it to the zone specification, it adds
        // an additional level of async nesting and so an additional trace.
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('chainForTrace'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inMicrotask'))));
      });
    });

    test('called for a stack trace from a one-shot timer', () {
      return Chain.capture(() {
        return chainForTrace(inOneShotTimer, () => throw 'error');
      }).then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('chainForTrace'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
      });
    });

    test('called for a stack trace from a periodic timer', () {
      return Chain.capture(() {
        return chainForTrace(inPeriodicTimer, () => throw 'error');
      }).then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('chainForTrace'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('called for a stack trace from a nested series of asynchronous '
        'operations', () {
      return Chain.capture(() {
        return chainForTrace((callback) {
          inPeriodicTimer(() => inOneShotTimer(() => inMicrotask(callback)));
        }, () => throw 'error');
      }).then((chain) {
        expect(chain.traces, hasLength(5));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('chainForTrace'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inMicrotask'))));
        expect(chain.traces[3].frames,
            contains(frameMember(startsWith('inOneShotTimer'))));
        expect(chain.traces[4].frames,
            contains(frameMember(startsWith('inPeriodicTimer'))));
      });
    });

    test('called for a stack trace from a long future chain', () {
      return Chain.capture(() {
        return chainForTrace(inFutureChain, () => throw 'error');
      }).then((chain) {
        expect(chain.traces, hasLength(3));
        expect(chain.traces[0].frames.first, frameMember(startsWith('main')));
        expect(chain.traces[1].frames,
            contains(frameMember(startsWith('chainForTrace'))));
        expect(chain.traces[2].frames,
            contains(frameMember(startsWith('inFutureChain'))));
      });
    });

    test('called for an unregistered stack trace returns a chain wrapping that '
        'trace', () {
      var trace;
      var chain = Chain.capture(() {
        try {
          throw 'error';
        } catch (_, stackTrace) {
          trace = stackTrace;
          return new Chain.forTrace(stackTrace);
        }
      });

      expect(chain.traces, hasLength(1));
      expect(chain.traces.first.toString(),
          equals(new Trace.from(trace).toString()));
    });
  });

  test('forTrace() outside of capture() returns a chain wrapping the given '
      'trace', () {
    var trace;
    var chain = Chain.capture(() {
      try {
        throw 'error';
      } catch (_, stackTrace) {
        trace = stackTrace;
        return new Chain.forTrace(stackTrace);
      }
    });

    expect(chain.traces, hasLength(1));
    expect(chain.traces.first.toString(),
        equals(new Trace.from(trace).toString()));
  });
}
