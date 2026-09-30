import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class YouTubeUploader {
  final String accessToken;
  final String selectedChannelId;

  YouTubeUploader(this.accessToken, {required this.selectedChannelId});

  static const String _uploadInitiationUrl =
      'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status';
  static const int _chunkSize = 1024 * 1024 * 5;
  static const int _maxRetries = 5;

  static Future<String> uploadVideo({
    required File file,
    required String accessToken,
    required String channelId,
    required String title,
    String description = '',
    required Function(double) onProgress,
  }) async {
    final totalSize = await file.length();

    final initRes = await http.post(
      Uri.parse(_uploadInitiationUrl),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': 'video/*',
        'X-Upload-Content-Length': totalSize.toString(),
      },
      body: jsonEncode({
        'snippet': {
          'title': title,
          'description': description,
          'channelId': channelId
        },
        'status': {
          'privacyStatus': 'private',
        },
      }),
    );

    if (initRes.statusCode != 200) {
      Fluttertoast.showToast(
        msg: "Failed to initiate upload: ${initRes.body}",
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.red,
        textColor: Colors.white,
      );
      throw Exception('Failed to initiate upload: ${initRes.body}');
    }

    final uploadUrl = initRes.headers['location'];
    if (uploadUrl == null) {
      Fluttertoast.showToast(
        msg: "Upload session URL not returned.",
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.red,
        textColor: Colors.white,
      );
      throw Exception('Upload session URL not returned');
    }

    final stream = file.openRead();
    int offset = 0;

    await for (final List<int> chunk in stream.transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (List<int> data, EventSink<List<int>> sink) {
        for (int i = 0; i < data.length; i += _chunkSize) {
          final end = (i + _chunkSize < data.length) ? i + _chunkSize : data.length;
          sink.add(data.sublist(i, end));
        }
      },
    ))) {
      int retries = 0;
      bool uploaded = false;

      while (!uploaded && retries < _maxRetries) {
        final chunkLength = chunk.length;
        final rangeHeader = 'bytes $offset-${offset + chunkLength - 1}/$totalSize';

        try {
          final uploadRes = await http.put(
            Uri.parse(uploadUrl),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Length': chunkLength.toString(),
              'Content-Type': 'video/*',
              'Content-Range': rangeHeader,
            },
            body: chunk,
          );

          if (uploadRes.statusCode == 200 || uploadRes.statusCode == 201) {
            final resBody = jsonDecode(uploadRes.body);
            return resBody['id'];
          } else if (uploadRes.statusCode == 308) {
            offset += chunkLength;
            onProgress(offset / totalSize);
            uploaded = true;
          } else {
            throw HttpException(
              'Unexpected status code: ${uploadRes.statusCode}',
              uri: Uri.parse(uploadUrl),
            );
          }
        } catch (e) {
          retries++;
          if (retries >= _maxRetries) {
            Fluttertoast.showToast(
              msg: "Upload failed: $e",
              toastLength: Toast.LENGTH_LONG,
              gravity: ToastGravity.BOTTOM,
              backgroundColor: Colors.red,
              textColor: Colors.white,
            );
            rethrow;
          }
          await Future.delayed(Duration(seconds: 2 * retries));
        }
      }
    }

    Fluttertoast.showToast(
      msg: "Upload failed after maximum retries.",
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
      backgroundColor: Colors.red,
      textColor: Colors.white,
    );
    throw Exception('Upload failed after maximum retries');
  }

  Future<String?> uploadResumable({
    required Uint8List videoBytes,
    required String title,
    String description = '',
    required Function(double) onProgress,
  }) async {
    final totalSize = videoBytes.length;

    final initRes = await http.post(
      Uri.parse(_uploadInitiationUrl),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': 'video/*',
        'X-Upload-Content-Length': totalSize.toString(),
      },
      body: jsonEncode({
        'snippet': {
          'title': title,
          'description': description,
          if (selectedChannelId.isNotEmpty) 'channelId': selectedChannelId,
        },
        'status': {'privacyStatus': 'private'},
      }),
    );

    if (initRes.statusCode != 200) throw Exception('Failed to initiate upload: ${initRes.body}');

    final uploadUrl = initRes.headers['location'];
    if (uploadUrl == null) throw Exception('Upload session URL not returned');

    int offset = 0;
    int retries = 0;

    while (offset < totalSize) {
      final end = (offset + _chunkSize) > totalSize ? totalSize : (offset + _chunkSize);
      final chunk = videoBytes.sublist(offset, end);
      final chunkLength = chunk.length;
      final rangeHeader = 'bytes $offset-${offset + chunkLength - 1}/$totalSize';

      try {
        final uploadRes = await http.put(
          Uri.parse(uploadUrl),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Length': chunkLength.toString(),
            'Content-Type': 'video/*',
            'Content-Range': rangeHeader,
          },
          body: chunk,
        );

        if (uploadRes.statusCode == 200 || uploadRes.statusCode == 201) {
          final resBody = jsonDecode(uploadRes.body);
          return resBody['id'];
        } else if (uploadRes.statusCode == 308) {
          offset += chunkLength;
          onProgress(offset / totalSize);
          retries = 0;
        } else {
          throw Exception('Unexpected status code: ${uploadRes.statusCode}');
        }
      } catch (e) {
        retries++;
        if (retries >= _maxRetries) rethrow;
        await Future.delayed(Duration(seconds: 2 * retries));
      }
    }

    throw Exception('Upload failed after maximum retries');
  }

  Future<List<Map<String, String>>> listPlaylists() async {
    final res = await http.get(
      Uri.parse('https://www.googleapis.com/youtube/v3/playlists?part=snippet&mine=true&maxResults=50'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body);
    return ((data['items'] as List?) ?? []).map<Map<String, String>>((p) => {
      'id': p['id'] as String? ?? '',
      'title': p['snippet']?['title'] as String? ?? '',
    }).toList();
  }

  Future<void> addToPlaylistById(String videoId, String playlistId) async {
    await http.post(
      Uri.parse('https://www.googleapis.com/youtube/v3/playlistItems?part=snippet'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'snippet': {
          'playlistId': playlistId,
          'resourceId': {'kind': 'youtube#video', 'videoId': videoId},
        },
      }),
    );
  }

  Future<void> addVideoToPlaylist(String videoId, String playlistName) async {
    final findRes = await http.get(
      Uri.parse('https://www.googleapis.com/youtube/v3/playlists?part=snippet&mine=true'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (findRes.statusCode != 200) return;

    final data = jsonDecode(findRes.body);
    final existing = (data['items'] as List?)?.firstWhere(
      (p) => (p['snippet']?['title'] as String?) == playlistName,
      orElse: () => null,
    );

    String? playlistId;
    if (existing != null) {
      playlistId = existing['id'] as String?;
    } else {
      final createRes = await http.post(
        Uri.parse('https://www.googleapis.com/youtube/v3/playlists?part=snippet'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'snippet': {
            'title': playlistName,
            'description': 'Auto-created folder: $playlistName',
          },
        }),
      );
      if (createRes.statusCode == 200) {
        playlistId = jsonDecode(createRes.body)['id'] as String?;
      }
    }

    if (playlistId != null) {
      await http.post(
        Uri.parse('https://www.googleapis.com/youtube/v3/playlistItems?part=snippet'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'snippet': {
            'playlistId': playlistId,
            'resourceId': {
              'kind': 'youtube#video',
              'videoId': videoId,
            },
          },
        }),
      );
    }
  }
}
