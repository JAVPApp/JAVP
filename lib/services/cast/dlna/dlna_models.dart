class DlnaRenderer {
  const DlnaRenderer({
    required this.usn,
    required this.name,
    required this.controlUrl,
    required this.serviceType,
  });

  final String usn;
  final String name;
  final Uri controlUrl;
  final String serviceType;
}
