import 'dart:typed_data';

/// Reads a '\0'-terminated string from the given [data] starting at [offset].
String readCString(Uint8List data, int offset) {
  final builder = BytesBuilder();
  for (var i = offset; i < data.length; i++) {
    final byte = data[i];
    if (byte == 0) {
      break;
    }
    builder.addByte(byte);
  }
  return String.fromCharCodes(builder.toBytes());
}

void writeCString(BytesBuilder builder, String string) {
  builder.add(string.codeUnits);
  builder.addByte(0);
}


int toHex(int char) {
  if (char >= 0x30 && char <= 0x39) {
    return char - 0x30;
  } else if (char >= 0x41 && char <= 0x46) {
    return char - 0x41 + 10;
  } else if (char >= 0x61 && char <= 0x66) {
    return char - 0x61 + 10;
  } else {
    throw ArgumentError.value(char, 'char', 'Not a hex character');
  }
}

typedef ReadByteFunction = int Function();

int readAsciiByte(int asciiUpperNibble, int asciiLowerNibble) {
  final high = toHex(asciiUpperNibble);
  final low = toHex(asciiLowerNibble);
  return high * 16 + low;
}
