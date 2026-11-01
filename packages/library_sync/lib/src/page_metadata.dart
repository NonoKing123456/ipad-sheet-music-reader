/// Optional directory metadata, separate from library transfers and ink state.
class PageMetadataKey {
  const PageMetadataKey(this.entryId, this.revisionId);
  final String entryId, revisionId;
  Map<String, Object?> toJson() => {
        'entryId': entryId,
        'revisionId': revisionId,
      };
  factory PageMetadataKey.fromJson(Map<String, dynamic> value) {
    final id = value['entryId'], revision = value['revisionId'];
    if (id is! String ||
        revision is! String ||
        id.isEmpty ||
        revision.isEmpty ||
        id.length > 256 ||
        revision.length > 256) {
      throw const FormatException('Invalid page metadata key.');
    }
    return PageMetadataKey(id, revision);
  }
  @override
  bool operator ==(Object other) =>
      other is PageMetadataKey &&
      entryId == other.entryId &&
      revisionId == other.revisionId;
  @override
  int get hashCode => Object.hash(entryId, revisionId);
}
