#include <sys/syscall.h>
#include <sys/types.h>

extern size_t _syscall1(size_t, size_t);
extern size_t _syscall6(size_t, size_t, size_t, size_t, size_t, size_t, size_t);

extern void main();

struct i_string_t {
    int64_t bytes;
    int8_t* ptr;
};

struct i_void_t {
};

void __irert__exit__(int64_t);

int8_t* __irert__gc_alloc__(int64_t);
void __irert__print__(struct i_string_t);

void _start() {
    main();
    __irert__exit__(0);
}

void __irert__exit__(int64_t status) {
    _syscall1(SYS_exit, status);
}



int64_t writefd(int32_t fd, int8_t* buffer, size_t count){
    // buffer should be zero-extended
    return _syscall6(SYS_write, fd, (size_t) buffer, count, 0, 0, 0);
}

int64_t __irert__writefd__(int64_t fd, struct i_string_t str){
    return writefd(fd, str.ptr, str.bytes);
}

int8_t* __irert__gc_alloc__(int64_t numbytes){
    return (int8_t*) _syscall6(SYS_mmap, 0, (size_t) numbytes, 0x3, 0x22, -1, 0);
}

void __irert__print__(struct i_string_t str){
    __irert__writefd__(1, str);
}

