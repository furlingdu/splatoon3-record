class UpdateInfo {
  const UpdateInfo({this.Tag = '', this.Notes = '', this.Url = '', this.Name = '', this.Size = 0});

  final String Tag;
  final String Notes;
  final String Url;
  final String Name;
  final int Size;

  bool get Available => Tag.isNotEmpty && Url.isNotEmpty;
}








