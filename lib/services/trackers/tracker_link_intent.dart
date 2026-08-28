import 'package:javp/models/metadata_settings.dart';

/// Whether this profile expects a tracker login that is missing on this device.
///
/// File-based sync only carries [MetadataSettings.wantSimklLink] (etc.).
/// Future JAVP cloud sync would restore the tokens themselves.
bool trackerNeedsDeviceLink({
  required MetadataSettings settings,
  required bool simklAuthenticated,
  required bool traktAuthenticated,
  bool serializdAuthenticated = false,
  bool betaseriesAuthenticated = false,
}) {
  if (settings.wantSimklLink && !simklAuthenticated) return true;
  if (settings.wantTraktLink && !traktAuthenticated) return true;
  if (settings.wantSerializdLink && !serializdAuthenticated) return true;
  if (settings.wantBetaseriesLink && !betaseriesAuthenticated) return true;
  return false;
}
