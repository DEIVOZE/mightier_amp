import 'dart:convert';

import 'package:mighty_plug_manager/bluetooth/NuxDeviceControl.dart';
import 'package:mighty_plug_manager/bluetooth/devices/NuxDevice.dart';
import 'package:mighty_plug_manager/bluetooth/devices/effects/Processor.dart';
import 'package:mighty_plug_manager/bluetooth/devices/presets/Preset.dart';
import 'package:mighty_plug_manager/platform/presetsStorage.dart';

/// Bridge between the current device state and an AI-friendly JSON format.
///
/// Exposes three static entry points:
/// - [exportDeviceSchema]   — describes the device's slots and available effects.
/// - [exportCurrentPreset]  — dumps the currently active preset.
/// - [importPresetFromJson] — creates and applies a preset from AI-produced JSON.
class AiJsonBridge {
  AiJsonBridge._();

  static const String _defaultCategory = 'Imports';

  /// Builds a compact JSON description of the device:
  /// product name, slots and their available effects with parameter ranges.
  static String exportDeviceSchema() {
    final NuxDevice device = NuxDeviceControl.instance().device;
    final Preset preset = device.getPreset(device.selectedChannel);

    final Map<String, dynamic> slots = <String, dynamic>{};

    for (int slot = 0; slot < device.effectsChainLength; slot++) {
      final List<Processor> slotEffects = preset.getEffectsForSlot(slot);
      final ProcessorInfo info = device.processorList[slot];

      final List<Map<String, dynamic>> effects = <Map<String, dynamic>>[];
      for (final Processor proc in slotEffects) {
        if (proc.isSeparator) continue;

        final List<Map<String, dynamic>> params = <Map<String, dynamic>>[];
        for (final Parameter p in proc.parameters) {
          params.add(<String, dynamic>{
            'name': p.name,
            'handle': p.handle,
            'min': p.formatter.min,
            'max': p.formatter.max,
            'type': p.formatter.inputType.toString(),
          });
        }

        effects.add(<String, dynamic>{
          'name': proc.name,
          'category': proc.category,
          'params': params,
        });
      }

      slots[info.keyName] = <String, dynamic>{
        'name': info.longName,
        'effects': effects,
      };
    }

    final Map<String, dynamic> schema = <String, dynamic>{
      'device': device.productName,
      'slots': slots,
    };

    return const JsonEncoder.withIndent('  ').convert(schema);
  }

  /// Dumps the currently active preset in a readable JSON format.
  static String exportCurrentPreset() {
    final NuxDevice device = NuxDeviceControl.instance().device;
    final Preset preset = device.getPreset(device.selectedChannel);

    final Map<String, dynamic> slots = <String, dynamic>{};

    for (int slot = 0; slot < device.effectsChainLength; slot++) {
      final ProcessorInfo info = device.processorList[slot];
      final List<Processor> slotEffects = preset.getEffectsForSlot(slot);
      final int selectedIndex = preset.getSelectedEffectForSlot(slot);

      final Map<String, dynamic> params = <String, dynamic>{};
      String model = '';
      if (selectedIndex >= 0 && selectedIndex < slotEffects.length) {
        final Processor selected = slotEffects[selectedIndex];
        model = selected.name;
        for (final Parameter p in selected.parameters) {
          params[p.name] = p.value;
        }
      }

      slots[info.keyName] = <String, dynamic>{
        'enabled': preset.slotEnabled(slot),
        'model': model,
        'params': params,
      };
    }

    final Map<String, dynamic> result = <String, dynamic>{
      'name': device.deviceControl.presetName.isNotEmpty
          ? device.deviceControl.presetName
          : 'Current Preset',
      'category': _defaultCategory,
      'device': device.productName,
      'volume': preset.volume,
      'slots': slots,
    };

    return const JsonEncoder.withIndent('  ').convert(result);
  }

  /// Applies [rawJson] to the currently active preset, saves the result to
  /// [PresetsStorage] and sends it to the device. Returns the saved name.
  ///
  /// The import drives the live [Preset] object (slot effects, parameters,
  /// volume) and then serializes it back with `device.presetToJson()`, instead
  /// of patching a JSON snapshot: that keeps `fx_type`, the parameter handles
  /// and the `inactiveEffects` list consistent with what `presetFromJson`
  /// expects to read back.
  static String importPresetFromJson(String rawJson) {
    final Map<String, dynamic> input = _parseJson(rawJson);

    final NuxDevice device = NuxDeviceControl.instance().device;
    final Preset preset = device.getPreset(device.selectedChannel);

    final String name = _resolveName(input['name']);
    final String category = _resolveCategory(input['category']);

    final Map<String, dynamic> inputSlots = _slotMap(input['slots']);
    final int chainLength = device.effectsChainLength;

    for (int slot = 0; slot < chainLength; slot++) {
      final String keyName = device.processorList[slot].keyName;

      final dynamic rawSlot = inputSlots[keyName];
      if (rawSlot is! Map) continue;
      final Map slotData = rawSlot;

      final dynamic enabledInput = slotData['enabled'];
      preset.setSlotEnabled(
        slot,
        enabledInput is bool ? enabledInput : true,
        false,
      );

      final dynamic modelInput = slotData['model'];
      if (modelInput is! String) continue;

      final String modelName = _normalize(modelInput);
      if (modelName.isEmpty) continue;

      final List<Processor> effects = preset.getEffectsForSlot(slot);

      int effectIndex = -1;
      for (int i = 0; i < effects.length; i++) {
        final Processor proc = effects[i];
        if (proc.isSeparator) continue;
        if (_normalize(proc.name) == modelName) {
          effectIndex = i;
          break;
        }
      }
      if (effectIndex < 0) continue;

      preset.setSelectedEffectForSlot(slot, effectIndex, false);

      _applyParams(
        preset,
        effects[effectIndex],
        slotData['params'],
      );
    }

    final dynamic volumeInput = input['volume'];
    if (volumeInput is num) {
      preset.setVolume(volumeInput.toDouble().clamp(0.0, 100.0), false);
    }

    // Serialize the preset we just configured, then save and push it.
    final Map<String, dynamic> internalJson =
        device.presetToJson(customPreset: preset);

    final String uuid = PresetsStorage().savePreset(
      internalJson,
      name,
      category,
    );

    device.deviceControl.presetName = name;
    device.deviceControl.presetCategory = category;
    device.deviceControl.presetUUID = uuid;

    device.presetFromJson(internalJson, null);

    return name;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _parseJson(String rawJson) {
    if (rawJson.trim().isEmpty) {
      throw const FormatException('Preset JSON is empty.');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException catch (e) {
      throw FormatException('Invalid preset JSON: ${e.message}');
    }

    if (decoded is! Map) {
      throw const FormatException('Preset JSON must be an object.');
    }

    if (!decoded.containsKey('slots')) {
      throw const FormatException('Preset JSON is missing "slots".');
    }
    if (decoded['slots'] is! Map) {
      throw const FormatException('Preset JSON "slots" must be an object.');
    }

    return decoded.map((dynamic key, dynamic value) =>
        MapEntry<String, dynamic>(key.toString(), value));
  }

  static String _resolveName(dynamic value) {
    if (value is String) {
      final String trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    final DateTime now = DateTime.now();
    return 'AI Preset ${now.hour}:${now.minute}';
  }

  static String _resolveCategory(dynamic value) {
    if (value is String) {
      final String trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return _defaultCategory;
  }

  static Map<String, dynamic> _slotMap(dynamic value) {
    final Map<String, dynamic> result = <String, dynamic>{};
    if (value is Map) {
      value.forEach((dynamic key, dynamic v) {
        result[key.toString()] = v;
      });
    }
    return result;
  }

  static String _normalize(String value) => value.toLowerCase().trim();

  /// Applies parameter values from [paramsInput] to [effect] on [preset].
  /// Values are matched either by parameter [Parameter.name] (case-insensitive)
  /// or by [Parameter.handle], then clamped to the formatter range.
  static void _applyParams(
    Preset preset,
    Processor effect,
    dynamic paramsInput,
  ) {
    if (paramsInput is! Map) return;

    final Map<String, dynamic> params = <String, dynamic>{};
    paramsInput.forEach((dynamic key, dynamic v) {
      params[key.toString().toLowerCase().trim()] = v;
    });

    for (final Parameter param in effect.parameters) {
      final String byName = _normalize(param.name);
      final String byHandle = _normalize(param.handle);

      dynamic rawValue;
      bool found = false;

      if (params.containsKey(byName)) {
        rawValue = params[byName];
        found = true;
      } else if (params.containsKey(byHandle)) {
        rawValue = params[byHandle];
        found = true;
      }

      if (!found) continue;

      final double? numeric = _toDouble(rawValue);
      if (numeric == null) continue;

      final double min = param.formatter.min.toDouble();
      final double max = param.formatter.max.toDouble();
      preset.setParameterValue(param, numeric.clamp(min, max), notify: false);
    }
  }

  static double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }
}
