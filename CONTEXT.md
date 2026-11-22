# CONTEXT — Mighty Amp (Flutter, NuX BLE devices)

Краткая карта архитектуры для задач на Mighty 8BT MKII / Lite MK2.

## 1. Активное устройство и модель 8BT MKII

- `lib/bluetooth/NuxDeviceControl.dart` — `class NuxDeviceControl extends ChangeNotifier`
  - singleton: `NuxDeviceControl.instance()` (factory), также `NuxDeviceControl()`.
  - `NuxDevice get device` — текущее активное устройство; `List<NuxDevice> get deviceList`.
  - `bool get isConnected`; `_device` берётся из `_deviceInstances` (индексы: NuxMightyPlug, PlugPro, Space, 8BT, 2040BT, Lite, LiteMk2, **NuxMighty8BTMk2**).
  - Выбор по id: `getDeviceFromId(String)`, `getDeviceFromPresetClass(String)`.
  - Пресет-мета: `presetName` (setter + `presetNameNotifier`), `presetCategory`, `presetUUID`, `clearPresetData()`, `forceNotifyListeners()`.
  - Запись на устройство: `requestPreset(int index)`, `saveNuxPreset()`, `sendParameter(param, bool returnOnly)`.
- `lib/bluetooth/devices/NuxDevice.dart` — `abstract class NuxDevice extends ChangeNotifier`
  - поля: `final NuxDeviceControl deviceControl`, `List<Preset> presets`, `List<String> channelNames`, `int selectedSlot`, стримы `effectSwitched/effectChanged/slotSwapped/parameterChanged`.
  - getters: `productName, productNameShort, productStringId, productVersion, presetClass, channelsCount, effectsChainLength, processorList, amplifierSlotIndex, cabinetSlotIndex, presetSaveSupport, activeChannelRetrieval, nativeActiveChannelsSupport`.
  - `int get selectedChannel`; `setSelectedChannel(int chan, {required bool notifyBT, required bool sendFullPreset, required bool notifyUI})`; `Preset getPreset(int index)`; `String channelName(int channel)`.
  - `Preset? presetFromJson(Map json, double? overrideLevel, {bool qrOnly, bool dontChangeChannel})` — применяет пресет к устройству.
  - `Map<String,dynamic> presetToJson({Preset? customPreset})` — сериализует текущий пресет (ключи = `ProcessorInfo.keyName`, + `inactiveEffects`).
  - `getProcessorInfoByKey(String)`, `getSlotByEffectKeyName(String)`.
- `lib/bluetooth/devices/NuxMighty8BTMk2.dart` — `class NuxMighty8BTMk2 extends NuxDevice` (интерфейсы Tuner/ProUsbSettings/DrumsTone/Looper)
  - `productName = "NUX Mighty 8BT MKII"`, `productNameShort = "Mighty 8BT MKII"`, `productStringId = "mighty_lite2"`, `presetClass = "mighty_amps_mk2"`, `productBLENames = ["NUX NGA-8BT","MIGHTY 8BT MKII"]`.
  - `int get deviceQRId => 0x14` (alt 0x13), `channelsCount = 7`, `effectsChainLength = 7`, `amplifierSlotIndex = 2`, `cabinetSlotIndex = 3`.
  - `LiteMK2Version version` (`enum LiteMK2Version { LiteMK2v1 }`); `productVersion => version.index`; `setFirmwareVersion(int)`.
  - `getCustomPreset(channel)` → `MightyMk2Preset`. Конфиг: `NuxMighty8BT2Configuration`.
- Базовый класс версии: `lib/bluetooth/devices/NuxMightyLiteMk2.dart` (тот же `MightyMk2Preset`).
- `deviceVersion`/`productString` как таковых нет: аналог — `productVersion` (`LiteMK2Version.index`) и `productStringId`.

## 2. Цепочка слотов и эффекты

- `NuxDevice.processorList` → для 8BT MKII `ProcessorsList.liteMk2List` в `lib/bluetooth/devices/device_data/processors_list.dart`.
  - `class ProcessorInfo {String shortName, longName, keyName; NuxFXID nuxFXID; Color color; IconData icon;}`.
  - Порядок слотов (Lite MK2): 0 gate, 1 efx, 2 amp, 3 cabinet(IR), 4 mod, 5 delay, 6 reverb.
  - Другие списки в том же файле: `plugProList`, `plugAirList`, `liteList`, `bt2040List`.
- `lib/bluetooth/devices/effects/Processor.dart`:
  - `abstract class Processor { String get name; List<Parameter> get parameters; int get nuxIndex; int? nuxEffectTypeIndex; int? nuxEnableIndex; EffectEditorUI editorUI; bool isSeparator; String category; }`
  - `abstract class Amplifier extends Processor { int get defaultCab; }`, `abstract class Cabinet { String get cabName; }`.
  - `class Parameter { String name; String handle; double value; ValueFormatter formatter; int midiCC; int devicePresetIndex; bool masterVolume; String get label; int get/set midiValue; double toHumanInput(); fromHumanInput(double); }`
  - Диапазон/тип значения — через `formatter`: `formatter.min`, `formatter.max` (int), `formatter.inputType` (`InputType.SliderInput/SwitchInput`), `formatter.toLabel(value)`.
  - `ValueFormatter` — `lib/bluetooth/devices/value_formatters/ValueFormatter.dart`; инстансы в `ValueFormatters.*` (percentage, percentageMPPro, decibelMPPro, tempoPro, switch-форматтеры).
- Пресет раскладки слотов: `lib/bluetooth/devices/presets/MightyMk2Preset.dart` (`class MightyMk2Preset extends Preset`)
  - списки эффектов: `noiseGate`, `_efxList`, `_amplifierList` (JazzClean, DeluxeRvb, TwinRvb, Brit800, ...), `_cabinetList` (+User IRs), `_modulationList`, `_delayList`, `_reverbList`.
  - `List<Processor> getEffectsForSlot(int slot)`, `int getSelectedEffectForSlot(int slot)`, `setSelectedEffectForSlot(int slot, int index, bool notifyBT)`, `slotEnabled(int)`, `setSlotEnabled(int,bool,bool)`.
  - `int getEffectArrayIndexFromNuxIndex(NuxFXID fxid, int nuxIndex)` — переход nuxIndex → индекс в списке.
  - имена эффектов: `processor.name`; категория для меню: `processor.category` + `isSeparator`; усилки: `preset.amplifierList[i].name`.
- Общие эффекты (plug_pro/*.dart, используются и в MK2): `JazzClean` и др. в `effects/plug_pro/Amps.dart`; усилки Native 8BT — `effects/mighty_8bt/Amps.dart` (`AmpClean`…, параметры gain/tone/level/miclevel).

## 3. Считывание текущего состояния (канал/крутилки)

- Активный канал: `device.selectedChannel`, `getPreset(selectedChannel)`.
- Значения крутилок: `effect.parameters[i].value` (актуальная величина), `label` — отформатированная строка.
- Данные с BLE: `Preset.addNuxPayloadPiece(data, part, total)` → `payloadPiecesReady()` → `Preset.setupPresetFromNuxData()` → `setupPresetFromNuxDataArray(List<int>)` (маппит `nuxData[devicePresetIndex]` в `Parameter.value`; в Mk2 переопределён и читает `volume` из `PresetDataIndexPlugPro.MASTER`).
- Изменения параметра с устройства: `NuxDevice._handleKnobReceiveData` (param.midiValue) → `notifyListeners()`.
- Ручная установка: `Preset.setParameterValue(Parameter param, double value, {bool notify = true})`.
- Смена канала: `device.setSelectedChannel(...)`; шаблон применения JSON: `device.presetFromJson(json, null)`.

## 4. Preset и PresetsStorage

- `abstract class Preset` — `lib/bluetooth/devices/presets/Preset.dart`
  - поля: `NuxDevice device; int channel; String channelName; List<List<int>> nuxDataPieces;`
  - `double get/set volume`, `void setVolume(double vol, bool btTransmit)`, `sendVolume()`.
  - абстрактные: `getEffectsForSlot`, `getSelectedEffectForSlot`, `slotEnabled`, `setFirmwareVersion`, `effectColor`.
  - `List<int> createNuxDataFromPreset()` (QR export).
  - Конструктор: `Preset({required this.device, required this.channel, required this.channelName})`.
- `lib/platform/presetsStorage.dart` — `class PresetsStorage extends ChangeNotifier`, singleton `PresetsStorage()`; файл `presets.json`.
  - `List presetsData` — список категорий: `{"name": String, "uuid": String, "presets": List<Map>}`.
  - `List<String> getCategories()`, `findPreset(String name, String category)`, `findPresetByUuid`, `findCategoryOfPreset(Map)`.
  - **Сохранение (новый пресет + запись в базу + уведомление UI):**
    `String savePreset(Map<String,dynamic> preset, String name, String categoryName)`
    - если пресет с таким `name` уже есть в категории — перезаписывает; иначе генерирует uuid и добавляет.
    - категория создаётся при отсутствии (`_findOrCreateCategory`).
    - внутри `_savePresets()` → запись json + `notifyListeners()`; слушатели `PresetStorageListener` (`onPresetCreated/Updated/Deleted`).
  - прочее: `deletePreset(Map)`, `renamePreset`, `duplicatePreset`, `changePresetCategory`, `presetsFromJson(String)` (импорт; ставит `"new": true`).
  - Ключи: `uuidKey = "uuid"`, `inactiveEffectsKey = "inactiveEffects"`.
- Минимальный JSON пресета для сохранения (из `NuxDevice.presetToJson()`):
  `{"channel": int, "product_id": presetClass, "version": productVersion, "volume": double, "<keyName>": {"fx_type": nuxIndex, "enabled": bool, "<param.handle>": value, ...}, ..., "inactiveEffects": {...}}`
- Типовой поток «сделать и сохранить пресет»:
  ```dart
  var dev = NuxDeviceControl.instance().device;
  var json = dev.presetToJson();           // или собрать вручную
  json["channel"] = 0;
  var uuid = PresetsStorage().savePreset(json, "My Patch", "Imports");
  dev.deviceControl.presetName = "My Patch";
  dev.deviceControl.presetCategory = "Imports";
  dev.deviceControl.presetUUID = uuid;
  // опционально: dev.presetFromJson(json, null); чтобы применить к устройству
  ```

## 5. UI-файлы (только имена, для будущих кнопок)

- `lib/UI/pages/settings.dart` — меню настроек.
- `lib/UI/widgets/presets/preset_list/presetList.dart` (рядом: `presetListMethods.dart`, `presets_popup_menus.dart`) — экран управления пресетами.
- Вспомогательно: `lib/UI/popups/savePreset.dart` (диалог сохранения), `lib/UI/pages/mighty_patches_importer.dart` (импорт), `lib/UI/pages/settings_advanced.dart`.
