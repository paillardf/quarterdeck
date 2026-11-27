// Where you were when Deck quit: the screen, the terminal panel open or not,
// the last section of each project, and choices a dialog keeps. Kept in
// cache/ui.json.
import 'dart:convert';
import 'dart:io';

class UiMemory {
  /// Reads [file] at once: the router needs the first screen before the first
  /// frame. Without a file it lives in memory only (tests, Widgetbook).
  UiMemory([this._file]) {
    try {
      final j = jsonDecode(_file!.readAsStringSync()) as Map<String, Object?>;
      location = j['location'] as String? ?? '/';
      panel = j['panel'] as bool? ?? false;
      places.addAll((j['places'] as Map? ?? const {}).cast());
      summaryNote = j['summaryNote'] as bool? ?? true;
    } on Object {
      // Not saved yet, or unreadable: start on the board.
    }
  }

  final File? _file;

  /// The route to open at start: "/project/vpn-ios?tab=mrs".
  String location = '/';

  /// The terminal panel was on screen.
  bool panel = false;

  /// Project id to the query of the section last open there: "tab=mrs".
  final places = <String, String>{};

  /// Publish review posts the summary note: the checkbox as last left.
  bool summaryNote = true;

  void setLocation(Uri u) {
    if (u.toString() == location) return;
    location = u.toString();
    if (u.pathSegments case ['project', final id] when u.query.isNotEmpty) places[id] = u.query;
    _save();
  }

  void setPanel(bool shown) {
    if (shown == panel) return;
    panel = shown;
    _save();
  }

  void setSummaryNote(bool on) {
    if (on == summaryNote) return;
    summaryNote = on;
    _save();
  }

  // Sync: a few bytes, and two writes in a row never interleave.
  void _save() {
    final f = _file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'location': location, 'panel': panel, 'places': places, 'summaryNote': summaryNote}));
    } on FileSystemException {
      // Not worth an error: the next start opens on the board.
    }
  }
}
