import 'package:flutter/material.dart';
import '../services/telegram_service.dart';

class TelegramAuthPage extends StatefulWidget {
  final TelegramService service;

  const TelegramAuthPage({Key? key, required this.service}) : super(key: key);

  @override
  State<TelegramAuthPage> createState() => _TelegramAuthPageState();
}

class _TelegramAuthPageState extends State<TelegramAuthPage> {
  int _step = 0;
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _connectAndSendCode() async {
    setState(() { _loading = true; _error = null; });
    try {
      await widget.service.connect();
      final phone = _phoneCtrl.text.trim();
      final result = await widget.service.sendCode(phone);
      if (result.error != null) {
        setState(() { _error = result.error.toString(); _loading = false; });
        return;
      }
      setState(() { _step = 1; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _signIn() async {
    setState(() { _loading = true; _error = null; });
    try {
      final result = await widget.service.signIn(_codeCtrl.text.trim());
      if (result.error != null) {
        final errStr = result.error.toString();
        if (errStr.contains('SESSION_PASSWORD_NEEDED') || errStr.contains('2FA')) {
          setState(() { _step = 2; _loading = false; });
          return;
        }
        setState(() { _error = errStr; _loading = false; });
        return;
      }
      await widget.service.saveSession();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _checkPassword() async {
    setState(() { _loading = true; _error = null; });
    try {
      final result = await widget.service.checkPassword(_pwdCtrl.text.trim());
      if (result.error != null) {
        setState(() { _error = result.error.toString(); _loading = false; });
        return;
      }
      await widget.service.saveSession();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  String get _label {
    switch (_step) {
      case 0: return 'Phone Number';
      case 1: return 'Verification Code';
      case 2: return '2FA Password';
      default: return '';
    }
  }

  String get _hint {
    switch (_step) {
      case 0: return '+1234567890';
      case 1: return '12345';
      case 2: return 'Enter your password';
      default: return '';
    }
  }

  Future<void> _submit() async {
    switch (_step) {
      case 0: await _connectAndSendCode(); break;
      case 1: await _signIn(); break;
      case 2: await _checkPassword(); break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Telegram Login')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 40),
            Icon(Icons.telegram, size: 80, color: Colors.blue[300]),
            const SizedBox(height: 24),
            Text(
              _label,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _step == 0 ? _phoneCtrl : (_step == 1 ? _codeCtrl : _pwdCtrl),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: _hint,
                hintStyle: TextStyle(color: Colors.grey[600]),
                filled: true,
                fillColor: Colors.grey[900],
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
              keyboardType: _step == 0 ? TextInputType.phone : TextInputType.text,
              obscureText: _step == 2,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loading ? null : _submit,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: Colors.blue,
              ),
              child: _loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Continue', style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}
