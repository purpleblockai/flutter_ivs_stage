import 'package:flutter/material.dart';

import '../../flutter_ivs_stage.dart';

/// Widget for joining a stage
class JoinStageWidget extends StatefulWidget {
  final String? initialToken;

  const JoinStageWidget({super.key, this.initialToken});

  @override
  State<JoinStageWidget> createState() => _JoinStageWidgetState();
}

class _JoinStageWidgetState extends State<JoinStageWidget> {
  late TextEditingController _tokenController;
  bool _isJoining = false;

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController(text: widget.initialToken);
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _joinStage() async {
    FocusManager.instance.primaryFocus?.unfocus();

    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      _showError('Please enter a valid token');
      return;
    }

    setState(() {
      _isJoining = true;
    });

    try {
      await FlutterIvsStage.joinStage(token);
    } catch (e) {
      _showError('Failed to Join: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isJoining = false;
        });
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Join',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _tokenController,
          decoration: InputDecoration(
            hintText: 'Enter stage token',
            hintStyle: TextStyle(color: Colors.grey[400]),
            filled: true,
            fillColor: Colors.grey[800],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
          style: const TextStyle(color: Colors.white),
          maxLines: 3,
          minLines: 1,
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: _isJoining ? null : _joinStage,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: _isJoining
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Text(
                  'Join',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
        ),
      ],
    );
  }
}
