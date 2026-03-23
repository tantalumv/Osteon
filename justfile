# Osteon Task Runner

build:
	odin build src/compiler -out:bin/osteon.exe -debug

run:
	odin run src/compiler -out:bin/osteon.exe -- examples/hello.ostn

check:
	odin run src/compiler -out:bin/osteon.exe -- --check examples/hello.ostn

test:
	# Run internal tests and golden file tests
	odin run src/compiler -out:bin/osteon.exe -- --test

clean:
	rm bin/osteon.exe
