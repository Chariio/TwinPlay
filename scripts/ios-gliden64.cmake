# Cache seed for GLideN64 on iOS. Passed as `cmake -C`.
# OpenGL is provided by OpenGLES.framework; VidExt (EAGL) creates the context.
set(OPENGL_FOUND TRUE CACHE BOOL "OpenGL ES on iOS" FORCE)
set(OPENGL_LIBRARIES "-framework OpenGLES" CACHE STRING "OpenGL ES" FORCE)
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DOS_IOS" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DOS_IOS" CACHE STRING "" FORCE)
