"""Hidden tests for the C7 spike. Written before any model output was seen.

Each test receives `f`, the function under test, and `out`, which calls f with
stdout captured and returns (return value, printed lines).
"""
import math
import re


def approx(a, b):
    return math.isclose(float(a), float(b), rel_tol=1e-6, abs_tol=1e-6)


def t_largest(f, out):
    assert f([3, 7, 2]) == 7
    assert f([-5, -2, -9]) == -2
    assert f([4]) == 4
    assert f([1, 5, 5, 0]) == 5


def t_vowels(f, out):
    assert f("hello") == 2
    assert f("rhythm") == 0
    assert f("banana") == 3
    assert f("programming is fun") == 5


def t_prime(f, out):
    assert f(2)
    assert f(17)
    assert not f(1)
    assert not f(15)
    assert f(97)


def t_average(f, out):
    assert approx(f([1, 2, 3, 4]), 2.5)
    assert approx(f([10]), 10)
    assert approx(f([2, 4]), 3)


def t_reverse(f, out):
    assert f("hello") == "olleh"
    assert f("") == ""
    assert f("ab c") == "c ba"


def t_linear_search(f, out):
    assert f([4, 8, 15], 8) == 1
    assert f([4, 8, 15], 99) == -1
    assert f([], 1) == -1
    assert f([5, 3, 5], 5) == 0


def t_bubble_sort(f, out):
    for given, want in (([5, 1, 4, 2, 8], [1, 2, 4, 5, 8]), ([], []), ([3, 3, 1], [1, 3, 3])):
        lst = list(given)
        r = f(lst)
        assert (r if r is not None else lst) == want


FIZZ15 = ["1", "2", "Fizz", "4", "Buzz", "Fizz", "7", "8", "Fizz", "Buzz",
          "11", "Fizz", "13", "14", "FizzBuzz"]


def t_fizzbuzz(f, out):
    _, lines = out(15)
    assert [l.strip().lower() for l in lines] == [s.lower() for s in FIZZ15]
    _, lines = out(5)
    assert [l.strip().lower() for l in lines] == [s.lower() for s in FIZZ15[:5]]


def t_celsius(f, out):
    assert approx(f(0), 32)
    assert approx(f(100), 212)
    assert approx(f(-40), -40)
    assert approx(f(37), 98.6)


def t_grade(f, out):
    assert f(70).upper() == "A"
    assert f(69).upper() == "B"
    assert f(60).upper() == "B"
    assert f(50).upper() == "C"
    assert f(49).upper() == "U"


def t_digit_sum(f, out):
    assert f(123) == 6
    assert f(0) == 0
    assert f(9999) == 36
    assert f(505) == 10


def t_factorial(f, out):
    assert f(0) == 1
    assert f(1) == 1
    assert f(5) == 120
    assert f(10) == 3628800


def t_palindrome(f, out):
    assert f("racecar")
    assert f("level")
    assert not f("hello")
    assert f("a")


def t_count_words(f, out):
    assert f("the cat sat") == 3
    assert f("hello") == 1
    assert f("one two three four five") == 5


def t_duplicates(f, out):
    assert set(f([1, 2, 3, 2, 4, 1])) == {1, 2}
    assert set(f([1, 2, 3])) == set()
    assert set(f([5, 5, 5])) == {5}


def t_binary_search(f, out):
    assert f([1, 3, 5, 7, 9], 7) == 3
    assert f([1, 3, 5, 7, 9], 1) == 0
    assert f([1, 3, 5, 7, 9], 4) == -1
    assert f([], 3) == -1


def t_times_table(f, out):
    _, lines = out(7)
    lines = [l for l in lines if l.strip()]
    assert len(lines) == 12
    for i, line in enumerate(lines, start=1):
        ints = [int(x) for x in re.findall(r"-?\d+", line)]
        assert i in ints and ints[-1] == 7 * i, line


def t_leap_year(f, out):
    assert f(2024)
    assert not f(1900)
    assert f(2000)
    assert not f(2023)


def t_password(f, out):
    assert f("abcdefg1")
    assert not f("abc1")
    assert not f("abcdefgh")
    assert f("12345678")
    assert f("password123")


def t_mean_odd(f, out):
    assert approx(f([1, 2, 3, 4, 5]), 3)
    assert approx(f([7]), 7)
    assert approx(f([2, 3, 4, 9]), 6)


TESTS = {name[2:]: fn for name, fn in list(globals().items()) if name.startswith("t_")}
