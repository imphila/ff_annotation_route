// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

final sdkPath = p.dirname(p.dirname(Platform.resolvedExecutable));

/// The SDK package, we filter this to the core libs and dev compiler
/// resources.
final PackageNode _sdkPackageNode =
    PackageNode(r'$sdk', sdkPath, DependencyType.hosted);

/// A graph of the package dependencies for an application.
class PackageGraph {
  /// The root application package.
  final PackageNode root;

  /// All [PackageNode]s indexed by package name.
  final Map<String, PackageNode> allPackages;

  PackageGraph._(this.root, Map<String, PackageNode> allPackages)
      : allPackages = Map.unmodifiable(
            Map<String, PackageNode>.from(allPackages)
              ..putIfAbsent(r'$sdk', () => _sdkPackageNode)) {
    if (!root.isRoot) {
      throw ArgumentError('Root node must indicate `isRoot`');
    }
    if (allPackages.values.where((n) => n != root).any((n) => n.isRoot)) {
      throw ArgumentError('No nodes other than the root may indicate `isRoot`');
    }
  }

  /// Creates a [PackageGraph] given the [root] [PackageNode].
  factory PackageGraph.fromRoot(PackageNode root) {
    final allPackages = <String, PackageNode>{root.name: root};

    void addDependency(PackageNode package) {
      for (final dep in package.dependencies) {
        if (allPackages.containsKey(dep.name)) continue;
        allPackages[dep.name] = dep;
        addDependency(dep);
      }
    }

    addDependency(root);

    return PackageGraph._(root, allPackages);
  }

  /// Creates a [PackageGraph] for the package whose top level directory lives
  /// at [packagePath] (no trailing slash).
  factory PackageGraph.forPath(String packagePath) {
    /// Read in the pubspec file and parse it as yaml.
    final pubspec = File(p.join(packagePath, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      throw StateError(
          'Unable to generate package graph, no `pubspec.yaml` found. '
          'This program must be ran from the root directory of your package.');
    }
    final rootPubspec = pubspecForPath(packagePath);
    final rootPackageName = rootPubspec['name'] as String;

    final packageLocations = _parsePackageLocations(packagePath)
      ..remove(rootPackageName);

    final dependencyTypes = _parseDependencyTypes(packagePath);

    final nodes = <String, PackageNode>{};
    final rootNode = PackageNode(
      rootPackageName,
      packagePath,
      DependencyType.path,
      isRoot: true,
    );
    nodes[rootPackageName] = rootNode;
    for (final packageName in packageLocations.keys) {
      if (packageName == rootPackageName) continue;
      nodes[packageName] = PackageNode(
        packageName,
        packageLocations[packageName],
        dependencyTypes[packageName],
        isRoot: false,
      );
    }

    rootNode.dependencies.addAll(
      _dependenciesFromYaml(
        rootPubspec,
        isRoot: true,
      ).map((n) => nodes[n]),
    );

    final packageDependencies = _parsePackageDependencies(packageLocations);
    for (final packageName in packageDependencies.keys) {
      nodes[packageName]
          .dependencies
          .addAll(packageDependencies[packageName].map((n) => nodes[n]));
    }
    return PackageGraph._(rootNode, nodes);
  }

  /// Creates a [PackageGraph] for the package in which you are currently
  /// running.
  factory PackageGraph.forThisPackage() => PackageGraph.forPath('./');

  /// Shorthand to get a package by name.
  PackageNode operator [](String packageName) => allPackages[packageName];

  @override
  String toString() {
    final buffer = StringBuffer();
    for (final package in allPackages.values) {
      buffer.writeln('$package');
    }
    return buffer.toString();
  }
}

/// A node in a [PackageGraph].
class PackageNode {
  /// The name of the package as listed in `pubspec.yaml`.
  final String name;

  /// The type of dependency being used to pull in this package.
  /// May be `null`.
  final DependencyType dependencyType;

  /// All the packages that this package directly depends on.
  final List<PackageNode> dependencies = [];

  /// The absolute path of the current version of this package.
  /// Paths are platform dependent.
  final String path;

  /// Whether this node is the [PackageGraph.root].
  final bool isRoot;

  PackageNode(this.name, String path, this.dependencyType, {bool isRoot})
      : path = _toAbsolute(path),
        isRoot = isRoot ?? false;

  @override
  String toString() => '''
  $name:
    type: $dependencyType
    path: $path
    dependencies: [${dependencies.map((d) => d.name).join(', ')}]''';

  /// Converts [path] to a canonical absolute path, returns `null` if given
  /// `null`.
  static String _toAbsolute(String path) =>
      (path == null) ? null : p.canonicalize(path);
}

/// Parse the `.packages` file and return a Map from package name to the file
/// location for that package.
Map<String, String> _parsePackageLocations(String rootPackagePath) {
  final packagesFile = File(p.join(rootPackagePath, '.packages'));
  if (!packagesFile.existsSync()) {
    throw StateError('Unable to generate package graph, no `.packages` found. '
        'This program must be ran from the root directory of your package.');
  }
  final packageLocations = <String, String>{};
  for (final line in packagesFile.readAsLinesSync().skip(1)) {
    final firstColon = line.indexOf(':');
    final name = line.substring(0, firstColon);
    assert(line.endsWith('lib/'));
    // Start after package_name:, and strip out trailing 'lib/'.
    var uriString = line.substring(firstColon + 1, line.length - 4);
    // Strip the trailing slash, if present.
    if (uriString.endsWith('/')) {
      uriString = uriString.substring(0, uriString.length - 1);
    }
    var uri = Uri.tryParse(uriString) ?? Uri.file(uriString);
    if (!uri.isAbsolute) {
      uri = p.toUri(p.join(rootPackagePath, uri.path));
    }
    packageLocations[name] = uri.toFilePath(windows: Platform.isWindows);
  }
  return packageLocations;
}

/// The type of dependency being used. This dictates how the package should be
/// watched for changes.
enum DependencyType { github, path, hosted, sdk }

/// Parse the `pubspec.lock` file and return a Map from package name to the type
/// of dependency.
Map<String, DependencyType> _parseDependencyTypes(String rootPackagePath) {
  final pubspecLock = File(p.join(rootPackagePath, 'pubspec.lock'));
  if (!pubspecLock.existsSync()) {
    throw StateError(
        'Unable to generate package graph, no `pubspec.lock` found. '
        'This program must be ran from the root directory of your package.');
  }
  final dependencyTypes = <String, DependencyType>{};
  final dependencies = loadYaml(pubspecLock.readAsStringSync()) as YamlMap;
  for (final packageName in dependencies['packages'].keys) {
    final source = dependencies['packages'][packageName]['source'];
    dependencyTypes[packageName as String] =
        _dependencyTypeFromSource(source as String);
  }
  return dependencyTypes;
}

DependencyType _dependencyTypeFromSource(String source) {
  switch (source) {
    case 'git':
      return DependencyType.github;
    case 'hosted':
      return DependencyType.hosted;
    case 'path':
      return DependencyType.path;
    case 'sdk': // Until Flutter supports another type, assume same as path.
      return DependencyType.sdk;
  }
  throw ArgumentError('Unable to determine dependency type:\n$source');
}

/// Read the pubspec for each package in [packageLocations] and finds it's
/// dependencies.
Map<String, Set<String>> _parsePackageDependencies(
    Map<String, String> packageLocations,
    {bool skipDevDependencies = false}) {
  final dependencies = <String, Set<String>>{};
  for (final packageName in packageLocations.keys) {
    final pubspec = pubspecForPath(packageLocations[packageName]);
    dependencies[packageName] = _dependenciesFromYaml(pubspec);
  }
  return dependencies;
}

/// Gets the dependencies from a yaml file, taking into account
/// dependency_overrides.
Set<String> _dependenciesFromYaml(YamlMap yaml, {bool isRoot = false}) {
  final dependencies = <String>{}
    ..addAll(_stringKeys(yaml['dependencies'] as Map));
  // if (isRoot) {
  dependencies..addAll(_stringKeys(yaml['dev_dependencies'] as Map));
  dependencies..addAll(_stringKeys(yaml['dependency_overrides'] as Map));
  // }
  return dependencies;
}

Iterable<String> _stringKeys(Map m) =>
    m == null ? const [] : m.keys.cast<String>();

/// Should point to the top level directory for the package.
YamlMap pubspecForPath(String absolutePath) {
  final pubspecPath = p.join(absolutePath, 'pubspec.yaml');
  final pubspec = File(pubspecPath);
  if (!pubspec.existsSync()) {
    throw StateError(
        'Unable to generate package graph, no `$pubspecPath` found.');
  }
  return loadYaml(pubspec.readAsStringSync()) as YamlMap;
}
