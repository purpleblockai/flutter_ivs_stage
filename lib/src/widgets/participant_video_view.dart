import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../flutter_ivs_stage.dart';

/// Google Meet-style avatar colors (same palette as participant_tile.dart).
const _avatarColors = [
  Color(0xFF2563EB), // blue-600
  Color(0xFF9333EA), // purple-600
  Color(0xFFDB2777), // pink-600
  Color(0xFF4F46E5), // indigo-600
  Color(0xFF7C3AED), // violet-600
  Color(0xFFC026D3), // fuchsia-600
  Color(0xFF0891B2), // cyan-600
  Color(0xFF0D9488), // teal-600
  Color(0xFF059669), // emerald-600
  Color(0xFF16A34A), // green-600
  Color(0xFF65A30D), // lime-600
  Color(0xFFD97706), // amber-600
  Color(0xFFEA580C), // orange-600
  Color(0xFFDC2626), // red-600
  Color(0xFFE11D48), // rose-600
];

/// Widget for displaying a participant's video stream
class ParticipantVideoView extends StatelessWidget {
  static final Set<String> _missingRemoteIdWarnings = <String>{};

  final StageParticipant participant;
  final bool showControls;
  final bool showOverlays;
  final bool isCompact;
  final bool showVideoPreview;
  final String? displayName;
  final String? roleLabel;
  final String? avatarUrl;
  final String? participantUid;

  const ParticipantVideoView({
    super.key,
    required this.participant,
    this.showControls = true,
    this.showOverlays = true,
    this.isCompact = false,
    this.showVideoPreview = true,
    this.displayName,
    this.roleLabel,
    this.avatarUrl,
    this.participantUid,
  });

  Color _avatarColor() {
    final uid = participantUid ?? participant.participantId ?? '';
    return _avatarColors[uid.hashCode.abs() % _avatarColors.length];
  }

  String _initials() {
    var name = displayName?.trim() ?? '';
    if (name.startsWith('@')) name = name.substring(1).trimLeft();
    if (name.isEmpty) return '?';
    final match = RegExp(r'[A-Za-z0-9]').firstMatch(name);
    return match?.group(0)?.toUpperCase() ?? name[0].toUpperCase();
  }

  String _resolvedDisplayName() {
    final name = displayName ??
        (participant.isLocal
            ? 'You (${participant.participantId ?? 'Disconnected'})'
            : participant.participantId ?? 'Unknown');
    if (roleLabel != null && roleLabel!.isNotEmpty) {
      return '$name ($roleLabel)';
    }
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final isAudioActive = !(participant.audioStream?.isMuted ?? true);

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        border: showOverlays && isAudioActive
            ? Border.all(color: Colors.green, width: 3.0)
            : null,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildVideoContent(),
          if (showOverlays) ...[
            if (!isCompact) ...[
              _buildParticipantInfo(),
              _buildStreamStatusIndicators(),
            ] else ...[
              _buildCompactOverlay(),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildVideoContent() {
    final videoStream = participant.videoStream;
    final hasVideoStream = videoStream != null;
    final isVideoMuted = videoStream?.isMuted ?? true;
    final participantId = participant.participantId;
    final hasRemoteId =
        participant.isLocal || (participantId?.trim().isNotEmpty ?? false);
    final shouldRenderPlatformView =
        showVideoPreview && hasRemoteId && hasVideoStream && !isVideoMuted;

    if (!participant.isLocal && !hasRemoteId) {
      final warnKey = (participantUid?.trim().isNotEmpty ?? false)
          ? participantUid!.trim()
          : ((displayName?.trim().isNotEmpty ?? false)
                ? displayName!.trim()
                : 'unknown_remote');
      if (_missingRemoteIdWarnings.add(warnKey)) {
        debugPrint(
          'ParticipantVideoView: skipping remote platform view due to missing participantId (key=$warnKey)',
        );
      }
    }

    // Keep rendering attached while a video stream exists.
    // IVS mute flags can be briefly stale during stream transitions.
    if (!shouldRenderPlatformView) {
      final radius = isCompact ? 20.0 : 28.0;

      Widget avatarWidget;
      if (avatarUrl != null && avatarUrl!.isNotEmpty) {
        avatarWidget = CircleAvatar(
          radius: radius,
          backgroundImage: NetworkImage(avatarUrl!),
          backgroundColor: _avatarColor(),
        );
      } else if (displayName != null && displayName!.trim().isNotEmpty) {
        avatarWidget = CircleAvatar(
          radius: radius,
          backgroundColor: _avatarColor(),
          child: Text(
            _initials(),
            style: TextStyle(
              color: Colors.white,
              fontSize: radius * 0.7,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      } else {
        avatarWidget = CircleAvatar(
          radius: radius,
          backgroundColor: _avatarColor(),
          child: Icon(Icons.person, size: radius, color: Colors.white),
        );
      }

      return ColoredBox(
        color: Colors.black,
        child: Center(child: avatarWidget),
      );
    }

    final creationParams = <String, dynamic>{
      'participantId': participantId,
      'isLocal': participant.isLocal,
    };

    if (Platform.isAndroid) {
      return SizedBox.expand(
        child: _buildAndroidVideoView(creationParams),
      );
    }

    return SizedBox.expand(
      child: UiKitView(
        viewType: 'ivs_video_view',
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }

  Widget _buildAndroidVideoView(Map<String, dynamic> creationParams) {
    return AndroidView(
      viewType: 'ivs_video_view',
      creationParams: creationParams,
      creationParamsCodec: const StandardMessageCodec(),
    );
  }

  Widget _buildParticipantInfo() {
    return Positioned(
      top: 8,
      left: 8,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _resolvedDisplayName(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildStreamStatusIndicators() {
    final isAudioMuted = participant.audioStream?.isMuted ?? true;
    final isVideoMuted = participant.videoStream?.isMuted ?? true;

    return Positioned(
      bottom: 8,
      right: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusIcon(
            icon: isAudioMuted ? Icons.mic_off : Icons.mic,
            isMuted: isAudioMuted,
          ),
          const SizedBox(width: 4),
          _StatusIcon(
            icon: isVideoMuted ? Icons.videocam_off : Icons.videocam,
            isMuted: isVideoMuted,
          ),
        ],
      ),
    );
  }

  Widget _buildCompactOverlay() {
    final name = displayName ??
        (participant.isLocal ? 'You' : participant.participantId ?? 'Unknown');
    return Positioned(
      bottom: 4,
      left: 4,
      right: 4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.icon, required this.isMuted});

  final IconData icon;
  final bool isMuted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        icon,
        size: 14,
        color: isMuted ? Colors.red : Colors.white,
      ),
    );
  }
}
