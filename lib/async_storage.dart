import 'dart:async';
import 'dart:io' show FileSystemEntity, FileSystemEntityType, Platform;
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class AsyncStorage {
  static const DB_NAME = "RKStorage";
  static const DATABASE_VERSION = 1;
  static const TABLE_CATALYST = "catalystLocalStorage";
  static AsyncStorage _instance;
  MethodChannel _channel;
  AsyncStorage._internal();

  factory AsyncStorage.create() {
    if (_instance == null) {
      _instance = AsyncStorage._internal();
      if (Platform.isIOS) {
        _instance._channel = const MethodChannel('datanor.ee/async_storage');
      }
    }
    return _instance;
  }

  Future<dynamic> get(String key) async {
    if (Platform.isIOS) {
      var value = await _channel.invokeMethod('multiGet', [key]);
      if( null != value ){
        return value[key];
      }
      return null;
    } else {
      Database _database;
      try {
        _database = await _openDb();
        if (_database != null) {
          var result = await _database
              .rawQuery("SELECT count(*) as cnt FROM sqlite_master WHERE type='table' and name = '$TABLE_CATALYST';");

          if (result[0]['cnt'] > 0) {
            List<Map> list =
                await _database.query(TABLE_CATALYST, columns: ["key", "value"], where: "key = ?", whereArgs: [key]);
            if (list.length > 0) {
              return list[0]["value"];
            }
          }
        }
        else{
          print("Database file not exist");
        }
      } finally {
        if (null != _database) {
          await _database.close();
        }
      }
    }
  }

  _openDb() async {
    var databasesPath = await getDatabasesPath();
    String path = join(databasesPath, DB_NAME);
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      return openDatabase(path, version: DATABASE_VERSION);
    }
    return null;
  }
}
