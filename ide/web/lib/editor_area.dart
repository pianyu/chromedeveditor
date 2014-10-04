// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

/**
 * A TabView associated with opened documents. It sends request to an
 * [EditorProvider] to create/refresh editors.
 */
library spark.editor_area;

import 'dart:async';
import 'dart:html' hide File;

import 'editors.dart';
import 'filesystem.dart';
import 'ui/widgets/tabview.dart';
import 'ui/widgets/imageviewer.dart';
import 'workspace.dart';

/// A tab associated with a file.
abstract class EditorTab extends Tab {
  final ContentProvider contentProvider;

  EditorTab(EditorArea parent, this.contentProvider) : super(parent) {
    label = contentProvider.name;
    _calculateTooltip(contentProvider).then((value) {
      tooltip = value;
    }).catchError((e) => null);
  }

  void resize();

  /**
   * Notify the Editor that the file contents have changed on disk.
   */
  void fileContentsChanged();
}

/// An [EditorTab] that contains an [AceEditor].
class AceEditorTab extends EditorTab {
  final Editor editor;
  final EditorProvider provider;

  bool _active = false;

  AceEditorTab(EditorArea parent, this.provider, this.editor,
      ContentProvider contentProvider) : super(parent, contentProvider) {
    page = editor.element;
    editor.onModification.listen((_) => parent.persistTab(contentProvider));
    editor.onDirtyChange.listen((_) => dirty = editor.dirty);
  }

  void activate() {
    _active = true;
    editor.activate();
    provider.activate(editor);
    super.activate();
  }

  void deactivate() {
    if (_active) editor.deactivate();
    _active = false;
    super.deactivate();
  }

  void focus() => editor.focus();

  void resize() => editor.resize();

  void fileContentsChanged() => editor.fileContentsChanged();
}

/// An [EditorTab] that contains an [ImageViewerTab].
class ImageViewerTab extends EditorTab {
  final ImageViewer imageViewer;
  final EditorProvider provider;

  ImageViewerTab(EditorArea parent, this.provider, this.imageViewer, ContentProvider contentProvider)
      : super(parent, contentProvider) {
    page = imageViewer.element;
  }

  void activate() {
    provider.activate(imageViewer);
    super.activate();
    resize();
  }

  void resize() => imageViewer.resize();

  void fileContentsChanged() => imageViewer.fileContentsChanged();
}

/**
 * Manages a list of open editors.
 */
class EditorArea extends TabView {
  final EditorProvider editorProvider;
  final Map<String, EditorTab> _tabOfUuid = {};

  bool allowsLabelBar;

  StreamController<String> _nameController = new StreamController.broadcast();

  EditorArea(Element parentElement, this.editorProvider, Workspace workspace,
             {this.allowsLabelBar: true})
      : super(parentElement) {
    onClose.listen((EditorTab tab) => closeFile(tab.contentProvider));
    showLabelBar = true;

    workspace.onResourceChange.listen((ResourceChangeEvent event) {
      // TODO(dvh): reflect name change instead of closing the file.
      event = new ResourceChangeEvent.fromList(event.changes, filterRename: true);
      for (ChangeDelta delta in event.changes) {
        if (delta.isDelete && delta.resource.isFile) {
          closeFile(delta.resource);
        } else if (delta.isChange && delta.resource.isFile) {
          _updateFile(delta.resource);
        }
      }
    });
  }

  Stream<String> get onNameChange => _nameController.stream;

  // TabView
  Tab add(EditorTab tab, {bool switchesTab: true}) {
    _tabOfUuid[tab.contentProvider.uuid] = tab;
    return super.add(tab, switchesTab: switchesTab);
  }

  // TabView
  Tab replace(EditorTab tabToReplace, EditorTab tab, {bool switchesTab: true}) {
    _tabOfUuid[tab.contentProvider.uuid] = tab;
    return super.replace(tabToReplace, tab, switchesTab: switchesTab);
  }

  // TabView
  bool remove(EditorTab tab, {bool switchesTab: true, bool layoutNow: true}) {
    if (super.remove(tab, switchesTab: switchesTab, layoutNow: layoutNow)) {
      _tabOfUuid.remove(tab.contentProvider.uuid);
      editorProvider.close(tab.contentProvider);
      return true;
    }
    return false;
  }

  /// Inform the editor area to layout it self according to the new size.
  void resize() {
    if (selectedTab != null) {
      (selectedTab as EditorTab).resize();
    }
  }

  /// Switches to a file. If the file is not opened and [forceOpen] is `true`,
  /// [selectFile] will be called instead. Otherwise the editor provider is
  /// requested to switch the file to the editor in case the editor is shared.
  Future selectFile(Resource file,
                    {bool forceOpen: false, bool switchesTab: true,
                    bool replaceCurrent: true, bool forceFocus: false}) {
    if (_tabOfUuid.containsKey(file)) {
      EditorTab tab = _tabOfUuid[file];
      if (switchesTab) tab.select(forceFocus: forceFocus);
      _nameController.add(file.name);
      return new Future.value();
    }

    Future editorReadyFuture;

    if (forceOpen || replaceCurrent) {
      EditorTab tab;

      ContentProvider contentProvider = new FileContentProvider(file);
      
      Editor editor = editorProvider.createEditorForContentProvider(contentProvider);
      editorReadyFuture = editor.whenReady;

      if (editor is ImageViewer) {
        tab = new ImageViewerTab(this, editorProvider, editor, contentProvider);
      } else {
        tab = new AceEditorTab(this, editorProvider, editor, contentProvider);
      }

      // On explicit request to open a tab, persist the new tab.
      if (!replaceCurrent) tab.persisted = true;

      // Don't replace the current tab if it's persisted.
      if ((selectedTab is AceEditorTab) &&
          (selectedTab as AceEditorTab).persisted) {
        replaceCurrent = false;
      }

      EditorTab tabToReplace = null;
      if (replaceCurrent) {
        tabToReplace = selectedTab;
      } else {
        tabToReplace = tabs.firstWhere((t) => !t.persisted, orElse: () => null);
      }

      if (tabToReplace != null) {
        replace(tabToReplace, tab, switchesTab: switchesTab);
      } else {
        add(tab, switchesTab: switchesTab);
      }

      if (forceFocus) tab.select(forceFocus: forceFocus);

      _nameController.add(file.name);
    } else {
      editorReadyFuture = new Future.value();
    }

    _savePersistedTabs();
    return editorReadyFuture;
  }

  void persistTab(ContentProvider contentProvider) {
    EditorTab tab = _tabOfUuid[contentProvider.uuid];
    if (tab != null) tab.persisted = true;
    _savePersistedTabs();
  }

  void _savePersistedTabs() {
    List<String> filesUuids = [];
    for (EditorTab tab in tabs) {
      if (tab.persisted) filesUuids.add(tab.contentProvider.uuid);
    }

    EditorManager manager = (editorProvider as EditorManager);
    manager.persistedFilesUuids = filesUuids;
    manager.persistState();
  }

  /// Closes the tab.
  void closeFile(ContentProvider contentProvider) {
    EditorTab tab = _tabOfUuid[contentProvider.uuid];

    if (tab != null) {
      remove(tab);
      tab.close();
      editorProvider.close(contentProvider);
      _nameController.add(selectedTab == null ? null : selectedTab.label);
      _savePersistedTabs();
    }
  }

  // Replaces the file loaded in a tab with a renamed version of the file. The
  // new tab is not selected.
  void renameFile(ContentProvider contentProvider) {
    if (_tabOfUuid.containsKey(contentProvider.uuid)) {
      EditorTab tab = _tabOfUuid[contentProvider.uuid];
      tab.label = contentProvider.name;
      _calculateTooltip(contentProvider).then((value) {
        tab.tooltip = value;
      }).catchError((e) => null);
      _nameController.add(selectedTab.label);
    }
  }

  void _updateFile(File file) {
    EditorTab tab = _tabOfUuid[file];
    if (tab != null) {
      tab.fileContentsChanged();
    }
  }
}

Future<String> _calculateTooltip(ContentProvider contentProvider) {
  if (!(contentProvider is FileContentProvider)) return new Future.value(contentProvider.name);
  File file = (contentProvider as FileContentProvider).file;
  if (file.entry == null) return new Future.value(file.path);

  return fileSystemAccess.getDisplayPath(file.entry);
}
