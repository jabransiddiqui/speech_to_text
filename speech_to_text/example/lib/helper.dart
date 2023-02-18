import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class Helper {
  Helper._privateConstructor();

  static final Helper instance = Helper._privateConstructor();
  String firstName = '';
  String familyName = '';
  String speakerName = '';
  bool closeManual = false;
  List<int> byteList = [];

  WebSocket? channel;

  wsConnection() {
    HttpClient client = HttpClient();
    client.badCertificateCallback =
        ((X509Certificate cert, String host, int port) => true);
    WebSocket.connect('wss://voicebiometric.xyz/diarization/',
            customClient: client)
        .then((value) {
      channel = (value);
      // channel?.pingInterval = const Duration(milliseconds: 1000);
      channel?.listen((webSocketData) {
        Map data = json.decode(webSocketData);
        debugPrint(data.toString());
      }, onError: (error) {
        debugPrint("Socket: error => $error");
        channel?.close();
        channel = null;
        Future.delayed(const Duration(seconds: 1)).then(
          (value) {
            wsConnection();
          },
        );
      }, onDone: () {
        debugPrint("Socket: done");
        channel?.close();
        channel = null;
        if (!closeManual) {
          Future.delayed(const Duration(seconds: 1)).then(
            (value) {
              wsConnection();
            },
          );
        }
      });
      debugPrint("webSocket——readyState:${channel?.readyState}");
      if (channel?.readyState == 1) {
      } else {}
    });
  }

  wsCloseConnection() {
    closeManual = true;
    channel?.close();
    channel = null;
  }

  Uint8List waveFormate(List<int> data) {
    var channels = 1;
    var bitSize = 16;
    var sampleRate = 16000;

    int byteRate = 16 * 16000 ~/ 8;

    var size = data.length;

    var fileSize = size + 36;

    Uint8List header = Uint8List.fromList([
      // "RIFF"
      82, 73, 70, 70,
      fileSize & 0xff,
      (fileSize >> 8) & 0xff,
      (fileSize >> 16) & 0xff,
      (fileSize >> 24) & 0xff,
      // WAVE
      87, 65, 86, 69,
      // fmt
      102, 109, 116, 32,
      // fmt chunk size 16
      16, 0, 0, 0,
      // Type of format
      1, 0,
      // One channel
      channels, 0,
      // Sample rate
      sampleRate & 0xff,
      (sampleRate >> 8) & 0xff,
      (sampleRate >> 16) & 0xff,
      (sampleRate >> 24) & 0xff,
      // Byte rate
      byteRate & 0xff,
      (byteRate >> 8) & 0xff,
      (byteRate >> 16) & 0xff,
      (byteRate >> 24) & 0xff,
      // Uhm
      (bitSize * channels) >> 3, 0,
      // bitsize
      bitSize, 0,
      // "data"
      100, 97, 116, 97,
      size & 0xff,
      (size >> 8) & 0xff,
      (size >> 16) & 0xff,
      (size >> 24) & 0xff,
      ...data
    ]);
    return header;
  }

  Future<String> createFolderInAppDocDir(String folderName) async {
    //Get this App Document Directory
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    //App Document Directory + folder name
    final Directory appDocDirFolder =
        Directory('${appDocDir.path}/$folderName/');

    if (await appDocDirFolder.exists()) {
      //if folder already exists return path
      return appDocDirFolder.path;
    } else {
      //if folder not exists create folder and then return its path
      final Directory appDocDirNewFolder =
          await appDocDirFolder.create(recursive: true);
      return appDocDirNewFolder.path;
    }
  }

  deleteDir() async {
    try {
      String folderInAppDocDir =
          await Helper.instance.createFolderInAppDocDir('voice_smaples');
      Directory directory = Directory(folderInAppDocDir);
      if (await directory.exists()) {
        directory.list(recursive: false).forEach((f) async {
          debugPrint(f.path);
          await f.delete();
        });
      }
      // await directory.delete(recursive: true);
    } catch (e) {
      debugPrint(e.toString());
    }
  }
}
