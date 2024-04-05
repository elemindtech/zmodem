import 'dart:core';
import 'dart:typed_data';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/crc.dart';
import 'package:zmodem/src/util/string.dart';
import 'package:zmodem/src/zmodem_frame.dart';



abstract class HeaderState {

  int get header => _parser._header; 
  set header(int hdr) => _parser._header = hdr; 
  int get type => _parser._type;
  set type(int type) => _parser._type = type;
  int get p0 => _parser._p0;
  set p0(int p0) => _parser._p0 = p0;
  int get p1 => _parser._p1;
  set p1(int p1) => _parser._p1 = p1;
  int get p2 => _parser._p2;
  set p2(int p2) => _parser._p2 = p2;
  int get p3 => _parser._p3;
  set p3(int p3) => _parser._p3 = p3;
  int get crc1 => _parser._crc1;
  set crc1(int crc1) => _parser._crc1 = crc1;
  int get crc2 => _parser._crc2;
  set crc2(int crc2) => _parser._crc2 = crc2;
  int get lastUpperNibble => _parser._lastUpperNibble;
  set lastUpperNibble(int lastUpperNibble) => _parser._lastUpperNibble = lastUpperNibble;
  int get count => _parser._count;
  set count(int count) => _parser._count = count;

  bool get doPrint => _parser._print;
  set doPrint(bool doPrint) => _parser._print = doPrint;

  List<int> get buffer => _parser._buffer;

  
  final ZModemHeaderParser _parser;
  HeaderState(this._parser);

  void _enter() {
    if(doPrint) {
      print('Enter $this');
    }
    count = 0;
  }

  void _exit() {
    if(doPrint) {
      print('Exit $this');
    }
  }

  ZModemHeader? _processByte(int byte);
  _reset(int val) {
    if(doPrint) {
      print('Reset $val');
    }
    _parser._header = -1;
    _parser._buffer = [];
    _parser._setState(_parser._headerState);
  }
}

class HexBodyState extends HeaderState {

  
  HexBodyState(super._parser);
  @override
  ZModemHeader? _processByte(int byte) {
    if((count & 0x01) == 0) {
      // Even length count
      _parser._lastUpperNibble = byte;
      count++;
    } else {
   
      int value = readAsciiByte(_parser._lastUpperNibble, byte);
      _parser._buffer.add(value);
      count = 0;

      if(_parser._buffer.length == 5) {
        type = value;
      } else if(_parser._buffer.length == 6) {
        p0 = value;
      } else if(_parser._buffer.length == 7) {
        p1 = value;
      } else if(_parser._buffer.length == 8) {
        p2 = value;
      } else if(_parser._buffer.length == 9) {
        p3 = value;
        _parser._setState(_parser._hexCrcState);
      } else {
        _reset(13);
      }
    }
    return null;
  }

  
  
}

class HexCrcState extends HeaderState {


  HexCrcState(super._parser);

  @override
  ZModemHeader? _processByte(int byte) {
    if((count & 0x01) == 0) {
      // Even length count
      lastUpperNibble = byte;
      count++;
    } else {
   
      int value = readAsciiByte(lastUpperNibble, byte);
      buffer.add(value);
      count = 0;

      if(buffer.length == 10) {
        crc1 = value;
      } else if(buffer.length == 11) {
        crc2 = value;
        int crc = ((crc1 << 8) | crc2);
        final ourCrc = CRC16()
            ..update(p0)
            ..update(p1)
            ..update(p2)
            ..update(p3)
            ..update(type)
            ..finalize();
        print('crc1: $crc1 crc2: $crc2  ourCrc: ${ourCrc.value}');
        if(crc == ourCrc.value) {
          if(header == consts.ZHEX) {
            _parser._setState(_parser._footerState);
          } else {
            _reset(1);
          }
        } else {
          _reset(2);
        }
      } else {
        _reset(3);
      }
    }
    return null;
  }
}
class FooterState extends HeaderState {
  


  FooterState(super._parser);

  @override
  ZModemHeader? _processByte(int byte) {
    print("Footer Byte: $byte Length: ${buffer.length}");
    if(buffer.length == 11) {
      if((byte & 0xFF) == 0x8D || (byte & 0xFF) == 0x0D) {
        buffer.add(byte);
      } else {
        _reset(4);
      }
    } else if (buffer.length == 12) {
      if((byte & 0xFF) == 0x8A || (byte & 0xFF) == 0x0A) {
        buffer.add(byte);
      } else {
        _reset(5);
      }
    } else if (buffer.length == 13 && byte == 17) { // XON
      ZModemHeader header = ZModemHeader(type, p0, p1, p2, p3);
      return header;
    } else {
      _reset(6);
    }
    return null;
  }
}


class PreambleState extends HeaderState {


  PreambleState(super._parser);

  @override
  ZModemHeader? _processByte(int byte) {
    if(byte == consts.ZPAD) {
      if(_parser._buffer.length < 2) {
        buffer.add(byte);
      } else {
        _reset(8);
      }
    } else if (byte == consts.ZDLE) {
      if(buffer.length == 2) {
         buffer.add(byte);
      } else  {
        _reset(9);
      }

    } else if(byte == consts.ZHEX) {
      header = byte;
      if(buffer.length == 3) {
          doPrint = true;
         buffer.add(byte);
         _parser._setState(_parser._hexBodyState);
      } else  {
        _reset(10);
      }
      
    } else {
      _reset(11);
    }
    return null;
  }
}




class ZModemHeaderParser {
  int _header = -1;
  int _type = 0;
  int _p0 = 0;
  int _p1 = 0;
  int _p2 = 0;
  int _p3 = 0;
  int _crc1 = 0;
  int _crc2 = 0;
  int _lastUpperNibble = 0;
  int _count = 0;

  bool _print = false;

  List<int> _buffer = [];
  late PreambleState _headerState;
  late HexBodyState _hexBodyState;
  late HexCrcState _hexCrcState;
  late FooterState _footerState;

  HeaderState? _state;

  ZModemHeaderParser() {
    _headerState = PreambleState(this);
    _hexBodyState = HexBodyState(this);
    _hexCrcState = HexCrcState(this);
    _footerState = FooterState(this);
    _state = _headerState;
  }

  ZModemHeader? processByte(int byte) {
    return _state?._processByte(byte);
  }

  void _setState(HeaderState state) {
    _state?._exit();
    _state = state;
    _state?._enter();
  }
}