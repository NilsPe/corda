/* Copyright (c) 2008-2014, Avian Contributors

   Permission to use, copy, modify, and/or distribute this software
   for any purpose with or without fee is hereby granted, provided
   that the above copyright notice and this permission notice appear
   in all copies.

   There is NO WARRANTY for this software.  See license.txt for
   details. */

#include "avian/process.h"

#include <avian/util/runtime-array.h>

using namespace vm;

namespace {

unsigned
mangledSize(int8_t c)
{
  switch (c) {
  case '_':
  case ';':
  case '[':
    return 2;

  case '$':
    return 6;

  default:
    return 1;
  }
}

unsigned
mangle(int8_t c, char* dst)
{
  switch (c) {
  case '/':
    dst[0] = '_';
    return 1;

  case '_':
    dst[0] = '_';
    dst[1] = '1';
    return 2;

  case ';':
    dst[0] = '_';
    dst[1] = '2';
    return 2;

  case '[':
    dst[0] = '_';
    dst[1] = '3';
    return 2;

  case '$':
    memcpy(dst, "_00024", 6);
    return 6;

  default:
    dst[0] = c;    
    return 1;
  }
}

unsigned
jniNameLength(Thread* t, GcMethod* method, bool decorate)
{
  unsigned size = 0;

  object className = reinterpret_cast<object>(method->class_()->name());
  for (unsigned i = 0; i < byteArrayLength(t, className) - 1; ++i) {
    size += mangledSize(byteArrayBody(t, className, i));
  }

  ++ size;

  object methodName = reinterpret_cast<object>(method->name());
  for (unsigned i = 0; i < byteArrayLength(t, methodName) - 1; ++i) {
    size += mangledSize(byteArrayBody(t, methodName, i));
  }

  if (decorate) {
    size += 2;

    object methodSpec = reinterpret_cast<object>(method->spec());
    for (unsigned i = 1; i < byteArrayLength(t, methodSpec) - 1
           and byteArrayBody(t, methodSpec, i) != ')'; ++i)
    {
      size += mangledSize(byteArrayBody(t, methodSpec, i));
    }
  }

  return size;
}

void
makeJNIName(Thread* t, const char* prefix, unsigned prefixLength, char* name,
            GcMethod* method, bool decorate)
{
  memcpy(name, prefix, prefixLength);
  name += prefixLength;

  object className = reinterpret_cast<object>(method->class_()->name());
  for (unsigned i = 0; i < byteArrayLength(t, className) - 1; ++i) {
    name += mangle(byteArrayBody(t, className, i), name);
  }

  *(name++) = '_';

  object methodName = reinterpret_cast<object>(method->name());
  for (unsigned i = 0; i < byteArrayLength(t, methodName) - 1; ++i) {
    name += mangle(byteArrayBody(t, methodName, i), name);
  }
  
  if (decorate) {
    *(name++) = '_';
    *(name++) = '_';

    object methodSpec = reinterpret_cast<object>(method->spec());
    for (unsigned i = 1; i < byteArrayLength(t, methodSpec) - 1
           and byteArrayBody(t, methodSpec, i) != ')'; ++i)
    {
      name += mangle(byteArrayBody(t, methodSpec, i), name);
    }
  }

  *(name++) = 0;
}

void*
resolveNativeMethod(Thread* t, const char* undecorated, const char* decorated)
{
  for (System::Library* lib = t->m->libraries; lib; lib = lib->next()) {
    void* p = lib->resolve(undecorated);
    if (p) {
      return p;
    } else {
      p = lib->resolve(decorated);
      if (p) {
        return p;
      }
    }
  }

  return 0;
}

void*
resolveNativeMethod(Thread* t, GcMethod* method, const char* prefix,
                    unsigned prefixLength, int footprint UNUSED)
{
  unsigned undecoratedSize = prefixLength + jniNameLength(t, method, false);
  // extra 6 is for code below:
  THREAD_RUNTIME_ARRAY(t, char, undecorated, undecoratedSize + 1 + 6);
  makeJNIName(t, prefix, prefixLength, RUNTIME_ARRAY_BODY(undecorated) + 1,
              method, false);

  unsigned decoratedSize = prefixLength + jniNameLength(t, method, true);
  // extra 6 is for code below:
  THREAD_RUNTIME_ARRAY(t, char, decorated, decoratedSize + 1 + 6);
  makeJNIName(t, prefix, prefixLength, RUNTIME_ARRAY_BODY(decorated) + 1,
              method, true);

  void* p = resolveNativeMethod(t, RUNTIME_ARRAY_BODY(undecorated) + 1,
                                RUNTIME_ARRAY_BODY(decorated) + 1);
  if (p) {
    return p;
  }

#ifdef PLATFORM_WINDOWS
  // on windows, we also try the _%s@%d and %s@%d variants
  if (footprint == -1) {
    footprint = methodParameterFootprint(t, method) + 1;
    if (method->flags() & ACC_STATIC) {
      ++ footprint;
    }
  }

  *RUNTIME_ARRAY_BODY(undecorated) = '_';
  vm::snprintf(RUNTIME_ARRAY_BODY(undecorated) + undecoratedSize + 1, 5, "@%d",
               footprint * BytesPerWord);

  *RUNTIME_ARRAY_BODY(decorated) = '_';
  vm::snprintf(RUNTIME_ARRAY_BODY(decorated) + decoratedSize + 1, 5, "@%d",
               footprint * BytesPerWord);

  p = resolveNativeMethod(t, RUNTIME_ARRAY_BODY(undecorated),
                          RUNTIME_ARRAY_BODY(decorated));
  if (p) {
    return p;
  }

  // one more try without the leading underscore
  p = resolveNativeMethod(t, RUNTIME_ARRAY_BODY(undecorated) + 1,
                          RUNTIME_ARRAY_BODY(decorated) + 1);
  if (p) {
    return p;
  }
#endif

  return 0;
}

object
resolveNativeMethod(Thread* t, GcMethod* method)
{
  void* p = resolveNativeMethod(t, method, "Avian_", 6, 3);
  if (p) {
    return reinterpret_cast<object>(makeNative(t, p, true));
  }

  p = resolveNativeMethod(t, method, "Java_", 5, -1);
  if (p) {
    return reinterpret_cast<object>(makeNative(t, p, false));
  }

  return 0;
}

} // namespace

namespace vm {

void
resolveNative(Thread* t, GcMethod* method)
{
  PROTECT(t, method);

  assertT(t, method->flags() & ACC_NATIVE);

  initClass(t, method->class_());

  if (getMethodRuntimeData(t, method)->native() == 0) {
    object native = resolveNativeMethod(t, method);
    if (UNLIKELY(native == 0)) {
      throwNew(t, GcUnsatisfiedLinkError::Type, "%s.%s%s",
               method->class_()->name()->body().begin(),
               method->name()->body().begin(),
               method->spec()->body().begin());
    }

    PROTECT(t, native);

    object runtimeData = reinterpret_cast<object>(getMethodRuntimeData(t, method));

    // ensure other threads only see the methodRuntimeDataNative field
    // populated once the object it points to has been populated:
    storeStoreMemoryBarrier();

    set(t, runtimeData, MethodRuntimeDataNative, native);
  } 
}

int
findLineNumber(Thread* t, GcMethod* method, unsigned ip)
{
  if (method->flags() & ACC_NATIVE) {
    return NativeLine;
  }

  // our parameter indicates the instruction following the one we care
  // about, so we back up first:
  -- ip;

  object code = reinterpret_cast<object>(method->code());
  object lnt = reinterpret_cast<object>(codeLineNumberTable(t, code));
  if (lnt) {
    unsigned bottom = 0;
    unsigned top = lineNumberTableLength(t, lnt);
    for (unsigned span = top - bottom; span; span = top - bottom) {
      unsigned middle = bottom + (span / 2);
      uint64_t ln = lineNumberTableBody(t, lnt, middle);

      if (ip >= lineNumberIp(ln)
          and (middle + 1 == lineNumberTableLength(t, lnt)
               or ip < lineNumberIp(lineNumberTableBody(t, lnt, middle + 1))))
      {
        return lineNumberLine(ln);
      } else if (ip < lineNumberIp(ln)) {
        top = middle;
      } else if (ip > lineNumberIp(ln)) {
        bottom = middle + 1;
      }
    }

    if (top < lineNumberTableLength(t, lnt)) {
      return lineNumberLine(lineNumberTableBody(t, lnt, top));
    } else {
      return UnknownLine;
    }
  } else {
    return UnknownLine;
  }
}

} // namespace vm
