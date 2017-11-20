#!/bin/bash
rake generate
proxychains4 rake deploy
