/// Turns a SAF tree URI into something worth showing a person.
///
/// A picked `content://` URI carries an opaque document id, not a path the user
/// recognises, so the label is rebuilt from the id's own convention:
///
///   ./tree/primary%3AMovies%2FAnime  -> "Internal storage › Movies › Anime"
///   ./tree/1A2B-3C4D%3ADownloads     -> "SD card › Downloads"
///
/// The volume part is only recognised for `primary` (internal storage); any
/// other volume is a removable drive whose serial is meaningless to a person,
/// so it collapses to "SD card". Anything unparseable is just "Folder" rather
/// than a raw id.
String folderLabelFromUri(Uri treeUri) {
  final segs = treeUri.pathSegments;
  final docId = segs.isEmpty ? '' : Uri.decodeComponent(segs.last);
  final colon = docId.indexOf(':');
  final volume = colon < 0 ? '' : docId.substring(0, colon);
  final path = colon < 0 ? docId : docId.substring(colon + 1);
  final root = volume.isEmpty
      ? null
      : (volume == 'primary' ? 'Internal storage' : 'SD card');
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  if (root == null && parts.isEmpty) return 'Folder';
  return [?root, ...parts].join(' › ');
}
