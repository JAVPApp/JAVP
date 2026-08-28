import 'package:javp/services/media_server/jellyfin_client.dart';

/// Emby uses the same MediaBrowser API family as Jellyfin.
class EmbyClient extends JellyfinClient {
  EmbyClient({super.httpClient})
      : super(clientName: 'JAVP', isEmby: true);
}
