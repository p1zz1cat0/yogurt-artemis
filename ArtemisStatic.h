//! @file
//! Copyright (C)2010 Daiju Hanaoka All rights reserved.

#include <string>
#include <vector>

//! �G���W���{��
class ArtemisStatic
{
public:
	//! �N��
	static void Launch(int argc, char* argv[], const char* option);
	//! �N��
	static void Launch(int argc, char* argv[], int mode, const char* option0, const char* option1);
	//! ������
	static void Initialize(void* stage);
	//! ���t���[�����s���郁�\�b�h
	static bool Execute();
	//! �^�b�`�J�n�n���h��
	static void TouchesBegan(std::vector<int>& touchesX, std::vector<int>& touchesY, std::vector<double>& touchesTime, int allTouchesCount);
	//! �^�b�`�ړ��n���h��
	static void TouchesMoved(std::vector<int>& touchesX, std::vector<int>& touchesY, std::vector<double>& touchesTime, std::vector<int>& previousTouchesX, std::vector<int>& previousTouchesY);
	//! �^�b�`�I���n���h��
	static void TouchesEnded(std::vector<int>& touchesX, std::vector<int>& touchesY, std::vector<double>& touchesTime);
	//! �����x�Z���T�[�n���h��
	static void Accelerometer(double x, double y, double z, double timeStamp);
	//! �����ύX�n���h��
	static void Orientation(int i);
	//! ���f
	static void Terminate();
	//! ���A
	static void EnterForeground();
	//! �������x��
	static void MemoryWarning();
	//! �I��
	static void Finalize();
	//! �^�O�����s
	static void ExecuteTag(const std::string& data);
	//! �L�[�C�x���g�𔭍s
	static void EmulateKeyEvent(int key, int status);
	//! �X�N���v�g�ϐ�����l���擾
	static void GetVariable(const char* name, std::string& result);
	//! �X�N���v�g�ϐ��ɒl��ݒ�
	static void SetVariable(const char* name, const std::string& data);
	//! �S�ẴT�E���h�̏�Ԃ�ݒ� (0: pause, 1: resume)
	static void SetAllSound(int status);
};
