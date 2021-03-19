// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:stack_trace/stack_trace.dart';

// ignore: one_member_abstracts
abstract class Tracer {
  R trace<R>(R Function() fn);
}

class PassThroughTracer implements Tracer {
  @override
  R trace<R>(R Function() fn) => fn();
}

abstract class _AbstractTracer implements Tracer {
  final _controller = StreamController<Trace>.broadcast();

  @override
  R trace<R>(R Function() fn) {
    if (_controller.hasListener && shouldSelect()) _emit();
    return fn();
  }

  Future<void> close() async {
    await _controller.close();
  }

  bool shouldSelect();

  Stream<Trace> get stream => _controller.stream;

  void _emit() {
    _controller.add(Trace.current(2)); // level = _emit + trace*
  }
}

class SamplingTracer extends _AbstractTracer {
  final int _rate;
  int _current;

  SamplingTracer({@required int rate})
      : _rate = rate,
        _current = rate;

  @override
  bool shouldSelect() {
    _current--;
    if (_current == 0) {
      _current = _rate;
      return true;
    }
    return false;
  }
}

class TraceAggregator {
  final _topDown = TraceTreeNode('topDown');
  final _bottomUp = TraceTreeNode('bottomUp');

  void add(Trace trace) {
    _topDown.addTrace(trace.frames.reversed);
    _bottomUp.addTrace(trace.frames);
  }

  Map<String, dynamic> asSortedMap() => {
        ..._topDown.asSortedMap(),
        ..._bottomUp.asSortedMap(),
      };

  String asSortedJson() {
    return JsonEncoder.withIndent('  ').convert(asSortedMap());
  }
}

final traceAggregator = TraceAggregator();

class TraceTreeNode {
  final String id;

  int counter = 0;
  List<TraceTreeNode> children;

  TraceTreeNode(this.id);

  void addTrace(Iterable<Frame> frames) {
    var node = this;
    node.counter++;
    for (final frame in frames) {
      if (frame.isCore) continue;
      final childId = '${frame.member} in ${frame.location}';
      node.children ??= <TraceTreeNode>[];
      final child = node.children.firstWhere(
        (n) => n.id == childId,
        orElse: () {
          final c = TraceTreeNode(childId);
          node.children.add(c);
          return c;
        },
      );
      child.counter++;
      node = child;
    }
  }

  Map<String, dynamic> asSortedMap({bool complete = false}) {
    if (children == null || children.isEmpty) {
      return {id: counter};
    } else {
      children.sort((a, b) => -a.counter.compareTo(b.counter));
      final map = <String, dynamic>{};
      final limit = complete ? 0 : counter ~/ 100;
      var skipped = 0;
      for (final c in children) {
        if (c.counter < limit) {
          skipped += c.counter;
          continue;
        }
        map.addAll(c.asSortedMap());
      }
      if (skipped > 0) {
        map['skipped'] = skipped;
      }
      return {'[$counter] $id': map};
    }
  }
}
