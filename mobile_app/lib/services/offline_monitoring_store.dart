import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/foot_frame.dart';
import '../models/offline_intervention.dart';

class OfflineMonitoringStore {
  static const _framesKey = 'footguard.offline_frame_pairs.v1';
  static const _baselineKey = 'footguard.local_baseline.v1';
  static const _interventionsKey = 'footguard.offline_interventions.v1';
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
        jsonEncode(bounded
            .map((pair) => pair.map((frame) => frame.toJson()).toList())
            .toList()),
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
          .map((item) =>
              OfflineIntervention.fromJson(item as Map<String, dynamic>))
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
}
