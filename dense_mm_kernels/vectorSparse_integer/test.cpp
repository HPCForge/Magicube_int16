#include <iostream>
#include <limits>

int main ()
{   
    signed char a = 127;
    signed char b = 0;
    b = a + 8;
    int an = a;
    int n = b;
    int inf_int = 0x7F800000;
    int test_int1 = 0x80000001;
    int mask = 0x0000000F;
    int test_int2 = test_int1 & mask;
    int int_array[2];
    int int_array_1[2];
    int_array[0] = 0x01100110;
    int_array[1] = 0x01111111;
    char * int_array_char = reinterpret_cast<char *>(int_array);
    char * int_array_1_char = reinterpret_cast<char *>(int_array_1);
    for(int i=0; i<2; i++)
        for(int j=0; j<4; j++){
            printf("%x\n", int_array_char[i*4+j]);	
            int_array_1_char[j*2+i] = int_array_char[i*4+j];	
	}
    printf("%x\n", int_array_1[0]);	
    printf("%x\n", int_array_1[1]);	
    
    //printf("%d %d %o\n", test_int1, test_int2, test_int2);
    //printf("%x %o\n", fl, fl);
    ////float inf = (float)0x7F800000;
    //float inf = *(float *)&inf_int;
    ////float inf = 1000000000000000000.0;
    ////float inf = std::numeric_limits<float>::infinity();
    //int fl = *(int*)&inf;
    //printf("%x %o\n", fl, fl);
    //float r = 0.0;
    ////r = inf/2.0;
    //r = inf - 11111111111000.0;
    //std::cout << "inf: " << inf << "inf_over_2: " << r << std::endl;
    //
    //std::cout << "an: " << an << "n: " << n << std::endl;
    //std::cout << "minimum value of int: "
    //          << std::numeric_limits<int>::min()
    //          << std::endl;
}
