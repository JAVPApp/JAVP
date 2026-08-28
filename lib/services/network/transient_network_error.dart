/// True for short-lived socket / DNS failures that are often safe to retry.
///
/// Android commonly surfaces background kills as
/// "Software caused connection abort" / ClientException.
bool isTransientNetworkError(Object e) {
  final text = e.toString().toLowerCase();
  return text.contains('connection abort') ||
      text.contains('connection closed') ||
      text.contains('connection reset') ||
      text.contains('broken pipe') ||
      text.contains('timed out') ||
      text.contains('timeout') ||
      text.contains('failed host lookup') ||
      text.contains('network is unreachable') ||
      text.contains('software caused connection abort') ||
      text.contains('clientexception') ||
      text.contains('socketexception') ||
      text.contains('http exception') ||
      text.contains('connection refused');
}
