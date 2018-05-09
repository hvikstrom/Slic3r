#!/usr/bin/python

from numpy import *
from math import *
from scipy.optimize import *
import sys


def usage():
    print "Need 3 arguments matching the levels of U, V and Z"
    sys.exit(0)

if (len(sys.argv) != 6 ):
    usage()

uz = -float(sys.argv[1])
zz = -float(sys.argv[2])
vz = -float(sys.argv[3])
A = float(sys.argv[4])
C = float(sys.argv[5])


def norme(x,y):
	return sqrt(pow(x, 2.0) + pow(y,2.0))

def myFunction(z):
	ux = z[0]
	uy = z[1]
	vx = z[2]
	vy = z[3]
	zy = z[4]

	B = sqrt(C**2.0 - (A/2.0)**2.0)
	phi = radians(26)#atan((B / 3.0) / ( A / 2.0 ))
	zx = A / 2.0

	F = empty((5))
	F[0] = vy + ( vx * tan(phi)) - (A * tan(phi))
	F[1] = uy - ( ux * tan(phi))
	F[2] = sqrt((ux - vx)**2.0 + (uy - vy)**2.0 + (uz - vz)**2.0) - A
	F[3] = sqrt((ux - zx)**2.0 + (uy - zy)**2.0 + (uz - zz)**2.0) - norme(B, (A/2.0))
	F[4] = sqrt((vx - zx)**2.0 + (vy - zy)**2.0 + (vz - zz)**2.0) - norme(B, (A/2.0))
	return F

zGuess = array([0.0,0.0,770.0,0.0,504.0])

z = fsolve(myFunction, zGuess)


print z[0]
print z[1]
print z[2]
print z[3]
print z[4]


	
