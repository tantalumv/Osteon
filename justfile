# Osteon Task Runner

build:
	odin build compiler -out:osteon.exe -debug

run:
	odin run compiler -out:osteon.exe -- examples/hello.ostn

check:
	odin run compiler -out:osteon.exe -- --check examples/hello.ostn

test:
	# Run internal tests and golden file tests
	odin run compiler -out:osteon.exe -- --test

clean:
	rm osteon.exe
