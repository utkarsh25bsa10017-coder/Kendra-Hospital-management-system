import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/module_list.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(KendraApp(modules: installedModules()));
}
