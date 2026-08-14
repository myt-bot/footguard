import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/foot_frame.dart';
import '../models/offline_intervention.dart';

class OfflineMonitoringStore {
  static const _framesKey = 'footguard.offline_frame_pairs.v1';
  static const _baselineKey = 'footguard.local_baseline.v1';
  static const _interventionsKey = 'footguard.offline_interventions.v1';
  static const _analyticsKey = 'footguard.session_analytics.v1';
  static const _sessionAdviceKey = 'footguard.session_advice.v1';
  static const _historyEventsKey = 'footguard.history_events.v1';
  static const _sessionSummaryKey = 'footguard.session_summary.v1';
  static const maxPairs = 1800;

  Future<List<List<FootFrame>>> loadPairs() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_framesKey);
      if (raw == null) return [];
      final rows = jsonDecode(raw) as List<dynamic>;
      return rows.map((row) {
        final pair = row as List<dynamic>;
        return pair
            .map((item) => FootFrame.fromJson(item as Map<String, dynamic>))
            .toList(growable: false);
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> savePairs(List<List<FootFrame>> pairs) async {
    try {
      final bounded = pairs.length <= maxPairs
          ? pairs
          : pairs.sublist(pairs.length - maxPairs);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _framesKey,
        jsonEncode(
          bounded
              .map((pair) => pair.map((frame) => frame.toJson()).toList())
              .toList(),
        ),
      );
    } catch (_) {
      // Memory queue remains available for this run.
    }
  }

  Future<Map<String, dynamic>?> loadBaseline() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_baselineKey);
      return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveBaseline(Map<String, dynamic> baseline) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_baselineKey, jsonEncode(baseline));
    } catch (_) {}
  }

  Future<void> clearBaseline() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_baselineKey);
    } catch (_) {}
  }

  Future<List<OfflineIntervention>> loadInterventions() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_interventionsKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List<dynamic>)
          .map(
            (item) =>
                OfflineIntervention.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveInterventions(List<OfflineIntervention> records) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _interventionsKey,
        jsonEncode(records.take(200).map((item) => item.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> loadAnalytics() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_analyticsKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAnalytics(List<Map<String, dynamic>> rows) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_analyticsKey, jsonEncode(rows));
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> loadSessionAdvice() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_sessionAdviceKey);
      return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSessionAdvice(Map<String, dynamic> advice) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_sessionAdviceKey, jsonEncode(advice));
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> loadHistoryEvents() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_historyEventsKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHistoryEvents(List<Map<String, dynamic>> events) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _historyEventsKey,
        jsonEncode(events.take(50).toList(growable: false)),
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> loadSessionSummary() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_sessionSummaryKey);
      return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSessionSummary(Map<String, dynamic> summary) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_sessionSummaryKey, jsonEncode(summary));
    } catch (_) {}
  }
}
