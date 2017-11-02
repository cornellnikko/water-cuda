PLATFORM=gcc
include ../config/Makefile.in.$(PLATFORM)

# ===
# Main driver and sample run

lshallow: ldriver.o shallow2d.o stepper.o
	$(NVCC) $(NVCCFLAGS) $(LUA_CFLAGS) -o $@ $^ $(LUA_LIBS) $(LIBS)

ldriver.o: ldriver.cu shallow2d.h
	$(NVCC) $(NVCCFLAGS) $(LUA_CFLAGS) -c $<

shallow2d.o: shallow2d.cu
	$(NVCC) $(NVCFLAGS) -c $<

stepper.o: stepper.cu shallow2d.o
	$(NVCC) $(NVCCFLAGS) -c $<

# ===
# Documentation

shallow.md: shallow2d.h shallow2d.c stepper.h stepper.c ldriver.c
	ldoc $^ -o $@

# ===
# Clean up

.PHONY: clean
clean:
	rm -f lshallow *.o
	rm -f shallow.md
	rm -f *.out
	rm -f *.mp4
	rm -f *.png
