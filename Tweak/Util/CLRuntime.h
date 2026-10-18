// Nil-safe helpers for touching private classes inside a system UI process. Never throw.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads an Objective-C object ivar (e.g. "_songDetailsView"). Returns nil if the object is nil,
/// the ivar does not exist, or the ivar is not an object type.
id _Nullable CLIvar(id _Nullable object, NSString *name);
/// Sets an object ivar the same way. Returns NO if it could not be set.
BOOL CLIvarSet(id _Nullable object, NSString *name, id _Nullable value);
/// [object valueForKey:] guarded against NSUndefinedKeyException. nil on failure.
id _Nullable CLValueForKey(id _Nullable object, NSString *key);
/// [object setValue:forKey:] guarded the same way. KVC raises for an unknown key *and* when the
/// value cannot be coerced to the property's type (a UIColor into a scalar, nil into a scalar),
/// and a raise inside a notification callback aborts the host — so every KVC write on a private
/// host object goes through this. Returns NO when nothing was written (nil object/value/key, or
/// the setter raised).
BOOL CLSetValueForKey(id _Nullable object, NSString *key, id _Nullable value);
/// Class by name, nil if absent. Logs once per missing class at debug level.
Class _Nullable CLClass(NSString *name);
/// YES if object responds to the selector named by string.
BOOL CLResponds(id _Nullable object, NSString *selectorName);
/// Returns the first subview (depth-first) of the given class name, or nil. The walk is bounded
/// in depth and in the number of views visited, so it cannot turn into a long walk inside a
/// layout pass however deep the host's hierarchy is.
id _Nullable CLFindSubview(id _Nullable view, NSString *className);
/// Multi-line recursive description of a view hierarchy (uses UIKit's private recursiveDescription when available).
NSString *CLViewHierarchy(id _Nullable view);

NS_ASSUME_NONNULL_END
