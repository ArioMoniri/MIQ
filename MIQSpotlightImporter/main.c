//
//  main.c — MIQSpotlightImporter
//
//  CFPlugIn glue for a classic Spotlight metadata importer (.mdimporter).
//
//  On macOS, `CSImportExtension` (the app-extension route) is accepted by the
//  system but does not index anything (Apple DTS), so the working mechanism is
//  still the legacy CFPlugIn bundle shipped in MIQ.app/Contents/Library/Spotlight.
//  This file is the COM-style factory + interface tables that `mdworker` expects,
//  adapted from Apple's former Xcode "Spotlight Importer" template. All metadata
//  work happens in Swift (`MIQImporterImportURL`, MIQSpotlightImporter.swift).
//
//  Both importer interfaces are exposed:
//    - kMDImporterURLInterfaceID → ImporterImportURLData (CFURLRef; preferred)
//    - kMDImporterInterfaceID    → ImporterImportData    (POSIX path; classic)
//  Neither import function dereferences `thisInterface`: Spotlight has been seen
//  passing an invalid pointer there for the URL interface.
//
//  The factory UUID below must match CFPlugInFactories / CFPlugInTypes in
//  Info.plist. Generated for MIQ; never reuse another importer's UUID.
//

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreServices/CoreServices.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>

#define MIQ_IMPORTER_FACTORY_ID "14059883-C04B-47A0-B570-4FC07264A531"

// Implemented in Swift via @_cdecl. Fills `attributes` from the file's header
// only; returns false (and leaves `attributes` untouched) for anything it does
// not recognise. `contentTypeUTI` may be NULL (the Swift side takes `CFString?`);
// `attributes` and `url` are checked non-NULL before the call.
extern Boolean MIQImporterImportURL(CFMutableDictionaryRef attributes, CFStringRef contentTypeUTI, CFURLRef url);

// MARK: - Instance layout

// One instance answers both interfaces. `fileInterface` must stay the first field:
// the instance pointer doubles as the classic (and IUnknown) interface pointer, the
// URL interface pointer is `&instance->urlInterface`, and each vtable's functions
// recover the instance from whichever one they were handed.
typedef struct MIQImporterPlugin {
    MDImporterInterfaceStruct *fileInterface;
    MDImporterURLInterfaceStruct *urlInterface;
    CFUUIDRef factoryID;
    // Atomic: mdworker may AddRef/Release the instance from more than one thread.
    _Atomic UInt32 refCount;
} MIQImporterPlugin;

static MIQImporterPlugin *MIQPluginFromFileInterface(void *thisInterface) {
    return (MIQImporterPlugin *)thisInterface;
}

static MIQImporterPlugin *MIQPluginFromURLInterface(void *thisInterface) {
    return (MIQImporterPlugin *)(void *)((char *)thisInterface - offsetof(MIQImporterPlugin, urlInterface));
}

// MARK: - Import functions

static Boolean MIQImportURLData(void *thisInterface, CFMutableDictionaryRef attributes, CFStringRef contentTypeUTI, CFURLRef url) {
    (void)thisInterface;
    if (attributes == NULL || url == NULL) {
        return false;
    }
    return MIQImporterImportURL(attributes, contentTypeUTI, url);
}

static Boolean MIQImportFileData(void *thisInterface, CFMutableDictionaryRef attributes, CFStringRef contentTypeUTI, CFStringRef pathToFile) {
    (void)thisInterface;
    if (attributes == NULL || pathToFile == NULL) {
        return false;
    }
    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, pathToFile, kCFURLPOSIXPathStyle, false);
    if (url == NULL) {
        return false;
    }
    Boolean result = MIQImporterImportURL(attributes, contentTypeUTI, url);
    CFRelease(url);
    return result;
}

// MARK: - Lifetime

static void MIQDeallocPlugin(MIQImporterPlugin *plugin) {
    CFUUIDRef factoryID = plugin->factoryID;
    free(plugin);
    if (factoryID != NULL) {
        CFPlugInRemoveInstanceForFactory(factoryID);
        CFRelease(factoryID);
    }
}

static ULONG MIQAddRef(MIQImporterPlugin *plugin) {
    return atomic_fetch_add(&plugin->refCount, 1) + 1;
}

static ULONG MIQRelease(MIQImporterPlugin *plugin) {
    // Decrement without going below zero; only the release that takes the count
    // from 1 to 0 frees the instance (an over-release must not double-free it).
    UInt32 current = atomic_load(&plugin->refCount);
    while (current > 0 && !atomic_compare_exchange_weak(&plugin->refCount, &current, current - 1)) {
    }
    if (current == 1) {
        MIQDeallocPlugin(plugin);
        return 0;
    }
    return current > 0 ? current - 1 : 0;
}

static HRESULT MIQQueryInterface(MIQImporterPlugin *plugin, REFIID iid, LPVOID *ppv) {
    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
    HRESULT result = E_NOINTERFACE;
    *ppv = NULL;
    if (interfaceID == NULL) {
        return result;
    }
    if (CFEqual(interfaceID, kMDImporterURLInterfaceID)) {
        MIQAddRef(plugin);
        *ppv = &plugin->urlInterface;
        result = S_OK;
    } else if (CFEqual(interfaceID, kMDImporterInterfaceID) || CFEqual(interfaceID, IUnknownUUID)) {
        MIQAddRef(plugin);
        *ppv = &plugin->fileInterface;
        result = S_OK;
    }
    CFRelease(interfaceID);
    return result;
}

// MARK: - Vtable thunks (one set per interface pointer)

static HRESULT MIQFileQueryInterface(void *thisInterface, REFIID iid, LPVOID *ppv) {
    return MIQQueryInterface(MIQPluginFromFileInterface(thisInterface), iid, ppv);
}

static ULONG MIQFileAddRef(void *thisInterface) {
    return MIQAddRef(MIQPluginFromFileInterface(thisInterface));
}

static ULONG MIQFileRelease(void *thisInterface) {
    return MIQRelease(MIQPluginFromFileInterface(thisInterface));
}

static HRESULT MIQURLQueryInterface(void *thisInterface, REFIID iid, LPVOID *ppv) {
    return MIQQueryInterface(MIQPluginFromURLInterface(thisInterface), iid, ppv);
}

static ULONG MIQURLAddRef(void *thisInterface) {
    return MIQAddRef(MIQPluginFromURLInterface(thisInterface));
}

static ULONG MIQURLRelease(void *thisInterface) {
    return MIQRelease(MIQPluginFromURLInterface(thisInterface));
}

static MDImporterInterfaceStruct MIQFileInterfaceTable = {
    NULL,
    MIQFileQueryInterface,
    MIQFileAddRef,
    MIQFileRelease,
    MIQImportFileData
};

static MDImporterURLInterfaceStruct MIQURLInterfaceTable = {
    NULL,
    MIQURLQueryInterface,
    MIQURLAddRef,
    MIQURLRelease,
    MIQImportURLData
};

// MARK: - Factory

static MIQImporterPlugin *MIQAllocPlugin(CFUUIDRef factoryID) {
    MIQImporterPlugin *plugin = (MIQImporterPlugin *)malloc(sizeof(MIQImporterPlugin));
    if (plugin == NULL) {
        return NULL;
    }
    plugin->fileInterface = &MIQFileInterfaceTable;
    plugin->urlInterface = &MIQURLInterfaceTable;
    plugin->factoryID = (CFUUIDRef)CFRetain(factoryID);
    CFPlugInAddInstanceForFactory(factoryID);
    atomic_init(&plugin->refCount, 1);
    return plugin;
}

// Named in Info.plist (CFPlugInFactories); must keep external linkage.
void *MIQImporterPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID);

void *MIQImporterPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;
    if (!CFEqual(typeID, kMDImporterTypeID)) {
        return NULL;
    }
    CFUUIDRef factoryID = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR(MIQ_IMPORTER_FACTORY_ID));
    if (factoryID == NULL) {
        return NULL;
    }
    MIQImporterPlugin *plugin = MIQAllocPlugin(factoryID);
    CFRelease(factoryID);
    return plugin;
}
